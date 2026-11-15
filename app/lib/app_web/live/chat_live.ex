defmodule AppWeb.ChatLive do
  @moduledoc """
  Chat LiveView over the `/live` WebSocket, paired with the raw channel
  client at `/probe`.

  Together they verify the whole socket path through the Worker and Durable
  Object: messages typed in either surface must appear in the other, which
  only works if the WebSocket upgrade, `Phoenix.PubSub` fan-out and
  `AppWeb.Presence` are all healthy inside the container.

  The diagnostics card is the point of the page. `app.js` configures
  `longPollFallbackMs`, so a broken WebSocket upgrade degrades to
  long-polling without any visible symptom — the `TransportInfo` hook
  reports the transport actually in use so a degraded connection is obvious.
  """

  use AppWeb, :live_view

  alias App.Chat
  alias AppWeb.Presence

  @impl true
  def mount(params, _session, socket) do
    room = Chat.room_or_default(params["room"])

    # Rooms can be owned and private (see App.Chat); a room that denies
    # this caller bounces to the default room rather than rendering an
    # empty transcript that looks open. Only a real denial bounces — any
    # other gateway failure mounts and degrades exactly as before, with
    # the history read reporting d1_ready: false. (No loop risk: slugs are
    # always generated, so the default room can never be claimed.)
    case Chat.room_access(current_scope(socket), room) do
      {:error, :forbidden} ->
        {:ok,
         socket
         |> put_flash(:error, "You don't have access to that room.")
         |> push_navigate(to: ~p"/chat")}

      {:ok, access} ->
        mount_room(room, access, params, socket)

      {:error, _degraded} ->
        mount_room(room, %{room: nil, role: :link}, params, socket)
    end
  end

  defp mount_room(room, access, params, socket) do
    nickname = nickname(params)

    {messages, d1_ready} =
      case Chat.recent_messages(current_scope(socket), room) do
        {:ok, messages} -> {messages, true}
        {:error, _reason} -> {[], false}
      end

    if connected?(socket) do
      Chat.subscribe(room)
      # Phoenix.Presence has no subscribe/1 in 1.8, so take the presence
      # topic directly and handle the "presence_diff" broadcast below.
      Phoenix.PubSub.subscribe(App.PubSub, presence_topic(room))

      {:ok, _ref} =
        Presence.track(self(), presence_topic(room), nickname, %{
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
       nickname: nickname,
       d1_ready: d1_ready,
       durability: nil,
       error: nil,
       transport: nil,
       websocket?: nil,
       reconnects: 0,
       present: present_count(room),
       node_uptime_ms: uptime_ms(),
       message_count: length(messages)
     )
     |> stream(:messages, messages)}
  end

  # Starts a fresh shareable session. push_navigate remounts the LiveView, so
  # the old room's subscriptions and presence go with the old process.
  @impl true
  def handle_event("new_session", _params, socket) do
    {:noreply,
     push_navigate(socket, to: ~p"/chat/#{Chat.new_room()}?as=#{socket.assigns.nickname}")}
  end

  def handle_event("rename", %{"nickname" => nickname}, socket) do
    case String.trim(nickname) do
      "" ->
        {:noreply, socket}

      nickname ->
        nickname = String.slice(nickname, 0, 64)
        topic = presence_topic(socket.assigns.room)

        Presence.untrack(self(), topic, socket.assigns.nickname)

        {:ok, _ref} =
          Presence.track(self(), topic, nickname, %{
            online_at: System.system_time(:second),
            transport: "liveview"
          })

        {:noreply, assign(socket, nickname: nickname)}
    end
  end

  def handle_event("send", %{"body" => body}, socket) do
    case Chat.create_message(
           current_scope(socket),
           socket.assigns.room,
           socket.assigns.nickname,
           body
         ) do
      {:ok, _message, durability} ->
        # The broadcast comes back through handle_info, so the message is
        # streamed there — proving the PubSub round trip rather than
        # short-circuiting it locally.
        {:noreply, assign(socket, durability: durability, error: nil)}

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
    {:noreply, assign(socket, present: present_count(socket.assigns.room))}
  end

  # Membership revoked mid-session (App.Chat.unshare_room/3). Authorization
  # is otherwise only checked on mount, so without this a revoked member
  # would keep receiving the room's broadcasts until they reloaded.
  def handle_info({:access_revoked, user_id}, socket) do
    case current_scope(socket) do
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

  # A client-supplied nickname, so the same person keeps their name across a
  # "new session" navigation; falls back to a random one.
  defp nickname(params) do
    case params["as"] do
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
    "live-" <> (:crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower))
  end

  # /chat is mountable anonymously, so current_scope may be absent (it is
  # only assigned inside a live_session with a UserAuth on_mount hook) or
  # nil — both read as an anonymous caller, which App.Chat accepts.
  defp current_scope(socket), do: socket.assigns[:current_scope]

  defp presence_topic(room), do: "room:" <> room

  defp present_count(room), do: map_size(Presence.list(presence_topic(room)))

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
