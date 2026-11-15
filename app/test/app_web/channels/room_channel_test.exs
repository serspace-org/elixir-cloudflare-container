defmodule AppWeb.RoomChannelTest do
  @moduledoc """
  The channel assumes an authenticated socket: `AppWeb.UserSocket.connect/3`
  has already resolved the account and assigned the scope, which is what
  `AppWeb.UserSocketTest` covers. These tests therefore build the socket with
  that scope directly rather than going through `connect/2`, so they can keep
  stubbing the gateway's message routes in memory.
  """

  use AppWeb.ChannelCase

  alias App.Accounts.Scope
  alias App.Accounts.User
  alias App.Chat

  @scope Scope.for_user(%User{id: 1, email: "tester@example.com"})

  defp join_room(topic \\ "room:lobby", scope \\ @scope) do
    socket(AppWeb.UserSocket, nil, %{scope: scope, nickname: Chat.sender_name(scope)})
    |> subscribe_and_join(topic, %{})
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

    test "joins a shared session room" do
      stub_d1_messages()
      room = App.Chat.new_room()

      assert {:ok, reply, _socket} = join_room("room:" <> room)
      assert reply.room == room
    end

    test "refuses a topic that is not a valid room slug" do
      stub_d1_messages()

      # Topics without the "room:" prefix are not routed to this channel at
      # all (see AppWeb.UserSocket), so they cannot even be attempted here.
      for topic <- ["room:", "room:Bad Room", "room:with/slash", "room:UPPER"] do
        assert {:error, %{reason: "unknown room"}} = join_room(topic),
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

      assert [
               %{
                 "body" => "hello from the channel",
                 "room" => "lobby",
                 "nickname" => "tester",
                 "user_id" => 1
               }
             ] = persisted_messages(store)
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

  describe "owned rooms" do
    # Room authorization is SQL in the gateway, so these run against the
    # sqlite-backed stub (see App.D1Stub.stub_d1_sqlite!/1).
    setup :stub_d1_sqlite!

    setup do
      import App.AccountsFixtures
      owner = user_scope_fixture()
      {:ok, room} = Chat.create_room(owner)
      %{owner: owner, room: room}
    end

    # Goes through the real handshake rather than socket/3, so these tests
    # cover the token the root layout mints as well as the channel.
    defp connect_as(scope) do
      {:ok, socket} =
        connect(AppWeb.UserSocket, %{
          "user_token" => AppWeb.UserAuth.user_socket_token(scope)
        })

      socket
    end

    test "the owner joins their private room through the socket identity",
         %{owner: owner, room: room} do
      assert {:ok, reply, _socket} =
               subscribe_and_join(connect_as(owner), "room:#{room.slug}", %{})

      assert reply.room == room.slug
    end

    test "a stranger is unauthorized, not unknown", %{room: room} do
      import App.AccountsFixtures
      stranger = user_scope_fixture()

      # "unauthorized" rather than "unknown room": a signed-in client can
      # tell "no such room" from "not yours".
      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(connect_as(stranger), "room:#{room.slug}", %{})

      # An identity-less client never reaches the channel at all — the
      # upgrade itself is refused (see AppWeb.UserSocket).
      assert :error = connect(AppWeb.UserSocket, %{})
    end

    test "a revoked member is pushed access_revoked and dropped",
         %{owner: owner, room: room} do
      import App.AccountsFixtures
      member = user_scope_fixture()
      {:ok, _shared} = Chat.share_room(owner, room.slug, member.user.email)

      assert {:ok, _reply, socket} =
               subscribe_and_join(connect_as(member), "room:#{room.slug}", %{})

      # The channel stops itself after the push; don't take the test down
      # with it.
      Process.unlink(socket.channel_pid)
      monitor = Process.monitor(socket.channel_pid)

      assert {:ok, 1} = Chat.unshare_room(owner, room.slug, member.user.id)
      assert_push "access_revoked", %{}
      assert_receive {:DOWN, ^monitor, :process, _pid, _reason}
    end

    test "other members stay connected when someone else is revoked",
         %{owner: owner, room: room} do
      import App.AccountsFixtures
      member = user_scope_fixture()
      bystander = user_scope_fixture()
      {:ok, _shared} = Chat.share_room(owner, room.slug, member.user.email)
      {:ok, _shared} = Chat.share_room(owner, room.slug, bystander.user.email)

      assert {:ok, _reply, _socket} =
               subscribe_and_join(connect_as(bystander), "room:#{room.slug}", %{})

      assert {:ok, 1} = Chat.unshare_room(owner, room.slug, member.user.id)
      refute_push "access_revoked", %{}
    end

    test "deleting the room pushes room_deleted and drops the channel",
         %{owner: owner, room: room} do
      assert {:ok, _reply, socket} =
               subscribe_and_join(connect_as(owner), "room:#{room.slug}", %{})

      Process.unlink(socket.channel_pid)
      monitor = Process.monitor(socket.channel_pid)

      assert :ok = Chat.delete_room(owner, room.slug)
      assert_push "room_deleted", %{}
      assert_receive {:DOWN, ^monitor, :process, _pid, _reason}
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
