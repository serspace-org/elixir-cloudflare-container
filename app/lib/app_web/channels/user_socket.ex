defmodule AppWeb.UserSocket do
  @moduledoc """
  Socket for the raw `Phoenix.Channel` chat client.

  Mounted at `/socket` in `AppWeb.Endpoint`, separately from LiveView's
  `/live`, and deliberately **without** a longpoll fallback: if the
  WebSocket upgrade through the Worker and Durable Object ever breaks, this
  socket must fail loudly instead of quietly degrading the way the
  LiveView socket would.

  Connections are anonymous — the demo has no accounts.
  """

  use Phoenix.Socket

  channel "room:*", AppWeb.RoomChannel

  @impl true
  def connect(params, socket, _connect_info) do
    socket =
      socket
      |> assign(:nickname, nickname(params))
      |> assign(:connected_at, System.system_time(:millisecond))

    {:ok, socket}
  end

  @impl true
  def id(_socket), do: nil

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
