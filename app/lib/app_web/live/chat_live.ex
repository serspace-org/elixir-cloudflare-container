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
    nickname = nickname(params)

    {messages, d1_ready} =
      case Chat.recent_messages(room) do
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
    case Chat.create_message(socket.assigns.room, socket.assigns.nickname, body) do
      {:ok, _message, durability} ->
        # The broadcast comes back through handle_info, so the message is
        # streamed there — proving the PubSub round trip rather than
        # short-circuiting it locally.
        {:noreply, assign(socket, durability: durability, error: nil)}

      {:error, changeset} ->
        {:noreply, assign(socket, error: changeset_message(changeset))}
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
