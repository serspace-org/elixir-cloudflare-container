defmodule AppWeb.UserSocket do
  @moduledoc """
  Socket for the raw `Phoenix.Channel` chat client.

  Mounted at `/socket` in `AppWeb.Endpoint`, separately from LiveView's
  `/live`, and deliberately **without** a longpoll fallback: if the
  WebSocket upgrade through the Worker and Durable Object ever breaks, this
  socket must fail loudly instead of quietly degrading the way the
  LiveView socket would.

  Connections may carry an identity, but don't have to: the root layout
  renders a short-lived `Phoenix.Token` for the logged-in user (see
  `sign_token/1`), the probe client passes it as `user_token`, and the
  socket resolves it to an `App.Accounts.Scope` in `:current_scope` — which
  is what lets `AppWeb.RoomChannel` join owned rooms. No token means an
  anonymous scope, which link rooms accept; a token that fails to verify
  refuses the connection outright, because silently downgrading a member to
  anonymous would read as "access denied" with no visible cause.
  """

  use Phoenix.Socket

  alias App.Accounts
  alias App.Accounts.Scope

  @token_salt "user socket"
  # The layout mints a fresh token on every page render, so this only has
  # to outlive one page's visit, not a session.
  @token_max_age_seconds 86_400

  channel "room:*", AppWeb.RoomChannel

  @doc "Signs a socket token for `user`, verified by `connect/3`."
  def sign_token(%Accounts.User{id: user_id}) do
    Phoenix.Token.sign(AppWeb.Endpoint, @token_salt, user_id)
  end

  @impl true
  def connect(params, socket, _connect_info) do
    with {:ok, scope} <- scope_from(params["user_token"]) do
      {:ok,
       socket
       |> assign(:current_scope, scope)
       |> assign(:nickname, nickname(params))
       |> assign(:connected_at, System.system_time(:millisecond))}
    end
  end

  # One id per user, so `AppWeb.UserAuth` can broadcast a "disconnect" when
  # they log out or change their password. Coarser than the per-session
  # `users_sessions:<token>` the LiveView socket uses — logging out one
  # browser drops the user's channel sockets everywhere — which errs on the
  # side of not leaving a socket authorized after its session died.
  @impl true
  def id(%{assigns: %{current_scope: %Scope{user: %{id: user_id}}}}),
    do: "users_sockets:#{user_id}"

  def id(_socket), do: nil

  defp scope_from(nil), do: {:ok, nil}

  defp scope_from(token) when is_binary(token) do
    with {:ok, user_id} <-
           Phoenix.Token.verify(AppWeb.Endpoint, @token_salt, token,
             max_age: @token_max_age_seconds
           ),
         %Accounts.User{} = user <- Accounts.get_user(user_id) do
      {:ok, Scope.for_user(user)}
    else
      _invalid -> :error
    end
  end

  defp scope_from(_token), do: :error

  defp nickname(params) do
    case params["nickname"] do
      name when is_binary(name) ->
        case String.trim(name) do
          "" -> random_nickname()
          trimmed -> String.slice(trimmed, 0, 64)
        end

      _other ->
        random_nickname()
    end
  end

  defp random_nickname do
    "guest-" <> (:crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower))
  end
end
