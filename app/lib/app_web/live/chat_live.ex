defmodule AppWeb.ChatLive do
  @moduledoc """
  Chat LiveView over the `/live` WebSocket, paired with the raw channel
  client at `/probe`.

  Together they verify the whole socket path through the Worker and Durable
  Object: messages typed in either surface must appear in the other, which
  only works if the WebSocket upgrade, `Phoenix.PubSub` fan-out and
  `AppWeb.Presence` are all healthy inside the container.

  Mounted in the `:require_authenticated_user` live session, so
  `@current_scope.user` is always present. The sender of a message is that
  user — `App.Chat.create_message/3` matches the scope — which is why there
  is no nickname field: a name the client could set is a name it could
  borrow from another account.

  The diagnostics card stays the point of the page. `app.js` configures
  `longPollFallbackMs`, so a broken WebSocket upgrade degrades to
  long-polling without any visible symptom — the `TransportInfo` hook
  reports the transport actually in use so a degraded connection is obvious.
  It is collapsed by default and forced open when the transport is not a
  WebSocket.
  """

  use AppWeb, :live_view

  alias App.Chat
  alias AppWeb.Presence

  @impl true
  def mount(params, _session, socket) do
    room = Chat.room_or_default(params["room"])
    scope = socket.assigns.current_scope

    # Rooms can be owned and private (see App.Chat); a room that denies
    # this caller bounces to the default room rather than rendering an
    # empty transcript that looks open. Only a real denial bounces — any
    # other gateway failure mounts and degrades exactly as before, with
    # the history read reporting d1_ready: false. (No loop risk: slugs are
    # always generated, so the default room can never be claimed.)
    case Chat.room_access(scope, room) do
      {:error, :forbidden} ->
        {:ok,
         socket
         |> put_flash(:error, "You don't have access to that room.")
         |> push_navigate(to: ~p"/chat")}

      {:ok, access} ->
        mount_room(room, scope, access, socket)

      {:error, _degraded} ->
        mount_room(room, scope, %{room: nil, role: :link}, socket)
    end
  end

  defp mount_room(room, scope, access, socket) do
    {messages, d1_ready} =
      case Chat.recent_messages(scope, room) do
        {:ok, messages} -> {messages, true}
        {:error, _reason} -> {[], false}
      end

    if connected?(socket) do
      Chat.subscribe(room)
      # Phoenix.Presence has no subscribe/1 in 1.8, so take the presence
      # topic directly and handle the "presence_diff" broadcast below.
      Phoenix.PubSub.subscribe(App.PubSub, presence_topic(room))

      # Keyed by user id, so two tabs of the same account are one person in
      # the roster rather than two.
      {:ok, _ref} =
        Presence.track(self(), presence_topic(room), presence_key(scope), %{
          name: Chat.sender_name(scope),
          online_at: System.system_time(:second),
          transport: "liveview"
        })
    end

    {:ok,
     socket
     |> assign(
       page_title: "Chat · #{room}",
       room: room,
       # The room's row (nil for an implicit link room) and this caller's
       # role in it — what lets the template say who the share link admits.
       chat_room: access.room,
       room_role: access.role,
       share_url: url(~p"/chat/#{room}"),
       probe_url: url(~p"/probe/#{room}"),
       nickname: Chat.sender_name(scope),
       d1_ready: d1_ready,
       durability: nil,
       error: nil,
       transport: nil,
       websocket?: nil,
       reconnects: 0,
       node_uptime_ms: uptime_ms(),
       message_count: length(messages)
     )
     |> assign_presence()
     |> stream(:messages, messages)}
  end

  # Starts a fresh shareable session. push_navigate remounts the LiveView, so
  # the old room's subscriptions and presence go with the old process.
  @impl true
  def handle_event("new_session", _params, socket) do
    {:noreply, push_navigate(socket, to: ~p"/chat/#{Chat.new_room()}")}
  end

  def handle_event("send", %{"body" => body}, socket) do
    case Chat.create_message(socket.assigns.current_scope, socket.assigns.room, body) do
      {:ok, _message, durability} ->
        # The broadcast comes back through handle_info, so the message is
        # streamed there — proving the PubSub round trip rather than
        # short-circuiting it locally.
        {:noreply,
         socket
         |> assign(durability: durability, error: nil)
         |> push_event("chat:sent", %{})}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, error: changeset_message(changeset))}

      {:error, :forbidden} ->
        {:noreply, assign(socket, error: "you don't have access to this room")}

      {:error, _reason} ->
        {:noreply, assign(socket, error: "message not delivered")}
    end
  end

  # Reported by the TransportInfo JS hook.
  def handle_event("transport_info", params, socket) do
    {:noreply,
     assign(socket,
       transport: params["transport"],
       websocket?: params["websocket"],
       reconnects: params["reconnects"] || 0,
       node_uptime_ms: uptime_ms()
     )}
  end

  @impl true
  def handle_info({:new_message, message}, socket) do
    {:noreply,
     socket
     |> stream_insert(:messages, message)
     |> assign(
       message_count: socket.assigns.message_count + 1,
       node_uptime_ms: uptime_ms()
     )}
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    {:noreply, assign_presence(socket)}
  end

  # Membership revoked mid-session (App.Chat.unshare_room/3). Authorization
  # is otherwise only checked on mount, so without this a revoked member
  # would keep receiving the room's broadcasts until they reloaded.
  def handle_info({:access_revoked, user_id}, socket) do
    case socket.assigns.current_scope do
      %{user: %{id: ^user_id}} ->
        {:noreply,
         socket
         |> put_flash(:error, "Your access to this room was revoked.")
         |> push_navigate(to: ~p"/chat")}

      _other ->
        {:noreply, socket}
    end
  end

  def handle_info({:room_deleted}, socket) do
    {:noreply,
     socket
     |> put_flash(:error, "This room was deleted.")
     |> push_navigate(to: ~p"/chat")}
  end

  ## Helpers

  @doc """
  True when `message` was sent by `scope`'s user.

  Messages written before `user_id` existed have no sender, so they are
  nobody's rather than everybody's.
  """
  def own_message?(scope, message) do
    not is_nil(message.user_id) and message.user_id == scope.user.id
  end

  # Timestamps come out of D1 as UTC (SQLite's CURRENT_TIMESTAMP), and the
  # server has no idea what the reader's zone is, so they are shown as UTC and
  # labelled as such rather than quietly presented as local time.

  @doc "A short clock time for a message, or nothing for an unparsed one."
  def message_time(nil), do: ""
  def message_time(%NaiveDateTime{} = inserted_at), do: Calendar.strftime(inserted_at, "%H:%M")

  @doc "The full timestamp, for the `<time>` element's tooltip."
  def message_title(nil), do: nil

  def message_title(%NaiveDateTime{} = inserted_at),
    do: Calendar.strftime(inserted_at, "%Y-%m-%d %H:%M:%S UTC")

  @doc "The machine-readable timestamp for a message's `<time>` element."
  def message_datetime(nil), do: nil

  def message_datetime(%NaiveDateTime{} = inserted_at),
    do: NaiveDateTime.to_iso8601(inserted_at) <> "Z"

  defp assign_presence(socket) do
    presences = Presence.list(presence_topic(socket.assigns.room))

    names =
      presences
      |> Enum.map(fn {key, %{metas: [meta | _rest]}} -> Map.get(meta, :name, key) end)
      |> Enum.sort()

    assign(socket, present: map_size(presences), present_names: names)
  end

  defp presence_key(scope), do: to_string(scope.user.id)

  defp presence_topic(room), do: "room:" <> room

  defp uptime_ms do
    {uptime_ms, _since_last} = :erlang.statistics(:wall_clock)
    uptime_ms
  end

  defp changeset_message(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.map_join("; ", fn {field, messages} ->
      "#{field} #{Enum.join(messages, ", ")}"
    end)
  end
end
