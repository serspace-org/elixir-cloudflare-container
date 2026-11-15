defmodule AppWeb.RoomChannel do
  @moduledoc """
  Chat channel used to verify WebSockets and Channels end to end.

  The socket is already authenticated by `AppWeb.UserSocket`, so every
  message is attributed to `socket.assigns.scope`'s account; the client
  supplies only the body.

  Beyond chat itself, it exposes two diagnostics:

    * `"ping"` replies with the client timestamp it was given plus server
      facts, so a client can measure real round-trip latency across the
      Worker -> Durable Object -> container hop.
    * `"diagnostics"` replies with node uptime and the live connection
      count, which is how you tell a WebSocket reconnect apart from a cold
      container restart.
  """

  use AppWeb, :channel

  alias App.Chat
  alias AppWeb.Presence

  require Logger

  @impl true
  def join("room:" <> room, _params, socket) do
    cond do
      not Chat.valid_room?(room) ->
        {:error, %{reason: "unknown room"}}

      # Rooms can be owned and private (see App.Chat). "unauthorized" is
      # deliberately distinct from "unknown room": a client can tell "no
      # such room" from "not yours". Only a real denial rejects the join —
      # any other gateway failure degrades exactly as before, with the
      # history read reporting d1_ready: false.
      match?({:error, :forbidden}, Chat.room_access(socket.assigns.scope, room)) ->
        {:error, %{reason: "unauthorized"}}

      true ->
        join_room(room, socket)
    end
  end

  def join(_topic, _params, _socket), do: {:error, %{reason: "unknown room"}}

  defp join_room(room, socket) do
    send(self(), :after_join)

    {history, d1_ready} =
      case Chat.recent_messages(socket.assigns.scope, room) do
        {:ok, messages} ->
          {messages, true}

        {:error, reason} ->
          Logger.warning("chat history unavailable for #{room}: #{inspect(reason)}")
          {[], false}
      end

    socket = assign(socket, room: room, d1_ready: d1_ready)

    {:ok,
     %{
       nickname: socket.assigns.nickname,
       room: room,
       d1_ready: d1_ready,
       messages: Enum.map(history, &render_message/1),
       server: server_info()
     }, socket}
  end

  @impl true
  def handle_info(:after_join, socket) do
    # Keyed by user id with the display name in the metas, matching
    # `AppWeb.ChatLive`: the two surfaces share a presence topic, so they have
    # to agree on what a key means or the same person shows up twice.
    {:ok, _ref} =
      Presence.track(socket, to_string(socket.assigns.scope.user.id), %{
        name: socket.assigns.nickname,
        online_at: System.system_time(:second),
        transport: transport_name(socket)
      })

    Chat.subscribe(socket.assigns.room)
    push(socket, "presence_state", Presence.list(socket))
    {:noreply, socket}
  end

  @impl true
  def handle_info({:new_message, message}, socket) do
    push(socket, "new_msg", render_message(message))
    {:noreply, socket}
  end

  # Membership revoked mid-session (App.Chat.unshare_room/3). Authorization
  # is otherwise only checked on join, so without this a revoked member
  # would keep receiving the room's broadcasts until they reconnected.
  def handle_info({:access_revoked, user_id}, socket) do
    case socket.assigns.scope do
      %{user: %{id: ^user_id}} ->
        push(socket, "access_revoked", %{})
        {:stop, :shutdown, socket}

      _other ->
        {:noreply, socket}
    end
  end

  def handle_info({:room_deleted}, socket) do
    push(socket, "room_deleted", %{})
    {:stop, :shutdown, socket}
  end

  @impl true
  def handle_in("new_msg", %{"body" => body}, socket) do
    case Chat.create_message(socket.assigns.scope, socket.assigns.room, body) do
      {:ok, _message, durability} ->
        {:reply, {:ok, %{durability: durability}}, socket}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:reply, {:error, %{reason: changeset_message(changeset)}}, socket}

      {:error, :forbidden} ->
        {:reply, {:error, %{reason: "unauthorized"}}, socket}

      {:error, _reason} ->
        {:reply, {:error, %{reason: "message not delivered"}}, socket}
    end
  end

  # Round-trip probe: the client sends its own clock, we echo it back so the
  # client can compute latency without trusting server/client clock skew.
  def handle_in("ping", params, socket) do
    {:reply, {:ok, Map.merge(%{client_ts: params["client_ts"]}, server_info())}, socket}
  end

  def handle_in("diagnostics", _params, socket) do
    {:reply, {:ok, Map.put(server_info(), :present, map_size(Presence.list(socket)))}, socket}
  end

  ## Helpers

  defp render_message(message) do
    %{
      id: message.id,
      nickname: message.nickname,
      body: message.body,
      inserted_at: message.inserted_at && NaiveDateTime.to_iso8601(message.inserted_at)
    }
  end

  defp server_info do
    {uptime_ms, _since_last} = :erlang.statistics(:wall_clock)

    %{
      node: to_string(node()),
      server_ts: System.system_time(:millisecond),
      node_uptime_ms: uptime_ms
    }
  end

  defp transport_name(socket) do
    socket.transport
    |> to_string()
    |> String.split(".")
    |> List.last()
  end

  defp changeset_message(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.map_join("; ", fn {field, messages} ->
      "#{field} #{Enum.join(messages, ", ")}"
    end)
  end
end
