defmodule AppWeb.UserSocket do
  @moduledoc """
  Socket for the raw `Phoenix.Channel` chat client.

  Mounted at `/socket` in `AppWeb.Endpoint`, separately from LiveView's
  `/live`, and deliberately **without** a longpoll fallback: if the
  WebSocket upgrade through the Worker and Durable Object ever breaks, this
  socket must fail loudly instead of quietly degrading the way the
  LiveView socket would.

  Connections require a logged-in account, like `/chat` and `/probe`
  themselves. A plain socket cannot read the session — `connect/3` sees only
  params and connect info — so the page hands back a token signed by
  `AppWeb.UserAuth.user_socket_token/1`; a missing, expired or forged one is
  a refused upgrade, and `AppWeb.RoomChannel` can then take the sender from
  `socket.assigns.scope` rather than from the client.
  """

  use Phoenix.Socket

  alias App.Accounts
  alias App.Accounts.Scope
  alias App.Chat
  alias AppWeb.UserAuth

  channel "room:*", AppWeb.RoomChannel

  @impl true
  def connect(params, socket, _connect_info) do
    with {:ok, user_id} <- UserAuth.verify_user_socket_token(params["user_token"]),
         %Accounts.User{} = user <- Accounts.get_user(user_id) do
      scope = Scope.for_user(user)

      {:ok,
       socket
       |> assign(:scope, scope)
       |> assign(:nickname, Chat.sender_name(scope))
       |> assign(:connected_at, System.system_time(:millisecond))}
    else
      _other -> :error
    end
  end

  # Identifying the socket is what lets logging out close it: `log_out_user/1`
  # broadcasts "disconnect" on this topic as well as the LiveView one, so a
  # `/probe` tab left open does not keep sending as an account that has
  # signed out. `AppWeb.UserAuth.user_socket_topic/1` owns the format.
  @impl true
  def id(%{assigns: %{scope: %Scope{user: %Accounts.User{id: user_id}}}}),
    do: UserAuth.user_socket_topic(user_id)
end
