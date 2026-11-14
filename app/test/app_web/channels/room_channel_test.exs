defmodule AppWeb.RoomChannelTest do
  use AppWeb.ChannelCase

  alias App.Chat

  defp join_room(params \\ %{"nickname" => "tester"}, topic \\ "room:lobby") do
    {:ok, socket} = connect(AppWeb.UserSocket, params)
    subscribe_and_join(socket, topic, %{})
  end

  describe "join/3" do
    test "replies with the nickname, room and server info" do
      stub_d1_messages()

      assert {:ok, reply, _socket} = join_room()
      assert reply.nickname == "tester"
      assert reply.room == "lobby"
      assert reply.d1_ready
      assert reply.messages == []
      assert is_integer(reply.server.node_uptime_ms)
    end

    test "replays history from D1, oldest first" do
      stub_d1_messages([
        %{"id" => 1, "room" => "lobby", "nickname" => "ada", "body" => "first"},
        %{"id" => 2, "room" => "lobby", "nickname" => "grace", "body" => "second"}
      ])

      assert {:ok, reply, _socket} = join_room()
      assert Enum.map(reply.messages, & &1.body) == ["first", "second"]
    end

    test "assigns a nickname when the client sends none" do
      stub_d1_messages()

      assert {:ok, reply, _socket} = join_room(%{})
      assert reply.nickname =~ ~r/^guest-[0-9a-f]{6}$/
    end

    test "joins a shared session room" do
      stub_d1_messages()
      room = App.Chat.new_room()

      assert {:ok, reply, _socket} = join_room(%{"nickname" => "guest"}, "room:" <> room)
      assert reply.room == room
    end

    test "refuses a topic that is not a valid room slug" do
      stub_d1_messages()
      {:ok, socket} = connect(AppWeb.UserSocket, %{})

      # Topics without the "room:" prefix are not routed to this channel at
      # all (see AppWeb.UserSocket), so they cannot even be attempted here.
      for topic <- ["room:", "room:Bad Room", "room:with/slash", "room:UPPER"] do
        assert {:error, %{reason: "unknown room"}} = subscribe_and_join(socket, topic, %{}),
               "expected #{topic} to be refused"
      end
    end

    test "joins with d1_ready: false when the gateway is unreachable" do
      stub_d1_unavailable()

      assert {:ok, reply, _socket} = join_room()
      refute reply.d1_ready
      assert reply.messages == []
    end
  end

  describe "new_msg" do
    test "persists the message and pushes it back over the socket" do
      store = stub_d1_messages()
      {:ok, _reply, socket} = join_room()

      ref = push(socket, "new_msg", %{"body" => "hello from the channel"})
      assert_reply ref, :ok, %{durability: :persisted}
      assert_push "new_msg", %{body: "hello from the channel", nickname: "tester"}

      assert [%{"body" => "hello from the channel", "room" => "lobby"}] =
               persisted_messages(store)
    end

    test "reaches subscribers that are not channels (the LiveView path)" do
      stub_d1_messages()
      {:ok, _reply, socket} = join_room()
      Chat.subscribe("lobby")

      ref = push(socket, "new_msg", %{"body" => "fan out"})
      assert_reply ref, :ok, _payload
      assert_receive {:new_message, %{body: "fan out"}}
    end

    test "stays usable but ephemeral when D1 is unreachable" do
      stub_d1_unavailable()
      {:ok, _reply, socket} = join_room()

      ref = push(socket, "new_msg", %{"body" => "no database here"})
      assert_reply ref, :ok, %{durability: :ephemeral}
      assert_push "new_msg", %{body: "no database here"}
    end

    test "rejects a blank body" do
      stub_d1_messages()
      {:ok, _reply, socket} = join_room()

      ref = push(socket, "new_msg", %{"body" => "   "})
      assert_reply ref, :error, %{reason: reason}
      assert reason =~ "body"
    end
  end

  describe "diagnostics" do
    test "ping echoes the client timestamp with server facts" do
      stub_d1_messages()
      {:ok, _reply, socket} = join_room()

      ref = push(socket, "ping", %{"client_ts" => 1234})
      assert_reply ref, :ok, reply
      assert reply.client_ts == 1234
      assert is_integer(reply.server_ts)
      assert is_integer(reply.node_uptime_ms)
    end

    test "counts the joined client as present" do
      stub_d1_messages()
      {:ok, _reply, socket} = join_room()

      # Presence is tracked in handle_info(:after_join); the ping round trip
      # guarantees that message has been processed.
      ref = push(socket, "ping", %{})
      assert_reply ref, :ok, _payload

      ref = push(socket, "diagnostics", %{})
      assert_reply ref, :ok, %{present: 1}
    end
  end
end
