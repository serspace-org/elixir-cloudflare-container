defmodule App.ChatTest do
  use ExUnit.Case

  import App.AccountsFixtures
  import App.D1Stub

  alias App.Chat

  setup tags do
    Req.Test.set_req_test_from_context(tags)
    :ok
  end

  describe "rooms" do
    test "new_room/0 generates a valid, unique slug" do
      slug = Chat.new_room()

      assert Chat.valid_room?(slug)
      refute slug == Chat.new_room()
    end

    test "valid_room?/1 rejects anything unsafe in a topic or a URL" do
      assert Chat.valid_room?("lobby")
      assert Chat.valid_room?("team-standup-2")

      refute Chat.valid_room?("")
      refute Chat.valid_room?("-leading-dash")
      refute Chat.valid_room?("Upper")
      refute Chat.valid_room?("with space")
      refute Chat.valid_room?("with/slash")
      refute Chat.valid_room?("room:nested")
      refute Chat.valid_room?(String.duplicate("a", 65))
      refute Chat.valid_room?(nil)
    end

    test "room_or_default/1 falls back for anything invalid" do
      assert Chat.room_or_default("standup") == "standup"
      assert Chat.room_or_default("Bad Room") == Chat.default_room()
      assert Chat.room_or_default(nil) == Chat.default_room()
    end

    test "messages are scoped per room" do
      stub_d1_messages()
      Chat.subscribe("one")

      assert {:ok, _message, :persisted} = Chat.create_message(nil, "two", "ada", "elsewhere")
      refute_receive {:new_message, _message}

      assert {:ok, _message, :persisted} = Chat.create_message(nil, "one", "ada", "here")
      assert_receive {:new_message, %{body: "here"}}
    end
  end

  test "create_message/4 broadcasts on the chat topic, not the channel topic" do
    stub_d1_messages()
    Chat.subscribe("lobby")
    # The channel topic; a broadcast here would double-deliver to channels.
    Phoenix.PubSub.subscribe(App.PubSub, "room:lobby")

    assert {:ok, message, :persisted} = Chat.create_message(nil, "lobby", "ada", "hi")
    assert message.id == 1

    assert_receive {:new_message, %{body: "hi"}}
    refute_receive {:new_message, _message}
  end

  test "create_message/4 trims and validates" do
    stub_d1_messages()

    assert {:error, changeset} = Chat.create_message(nil, "lobby", "ada", "  ")
    refute changeset.valid?
  end

  test "create_message/4 degrades to ephemeral without D1" do
    stub_d1_unavailable()

    assert {:ok, message, :ephemeral} = Chat.create_message(nil, "lobby", "ada", "hi")
    assert message.id
    assert message.inserted_at
  end

  test "recent_messages/3 surfaces gateway failures" do
    stub_d1_unavailable()

    assert {:error, :gateway_unreachable} = Chat.recent_messages(nil, "lobby")
  end

  describe "owned rooms" do
    # Room authorization is SQL in the gateway, so these run against the
    # sqlite-backed stub rather than hand-written responses that would lie
    # about the predicate (the same reasoning as the accounts tests).
    setup :stub_d1_sqlite!

    setup do
      owner = user_scope_fixture()
      member = user_scope_fixture()
      stranger = user_scope_fixture()
      %{owner: owner, member: member, stranger: stranger}
    end

    test "create_room/2 claims a fresh private slug for the owner", %{owner: owner} do
      assert {:ok, room} = Chat.create_room(owner, %{name: "  Standup  "})

      assert Chat.valid_room?(room.slug)
      assert room.visibility == "private"
      assert room.name == "Standup"
      assert room.role == :owner

      assert {:ok, [listed]} = Chat.list_rooms(owner)
      assert listed.slug == room.slug
      assert listed.role == :owner
    end

    test "create_room/2 validates", %{owner: owner} do
      assert {:error, changeset} = Chat.create_room(owner, %{visibility: "bogus"})
      refute changeset.valid?
    end

    test "an unclaimed slug stays an implicit link room", %{stranger: stranger} do
      assert {:ok, %{room: nil, role: :link}} = Chat.room_access(nil, Chat.default_room())
      assert {:ok, %{room: nil, role: :link}} = Chat.room_access(stranger, "never-claimed")
    end

    test "room_access/2 resolves owner, member, stranger and anonymous",
         %{owner: owner, member: member, stranger: stranger} do
      {:ok, room} = Chat.create_room(owner)
      {:ok, _member} = Chat.share_room(owner, room.slug, member.user.email)

      assert {:ok, %{role: :owner}} = Chat.room_access(owner, room.slug)
      assert {:ok, %{role: :member}} = Chat.room_access(member, room.slug)
      assert {:error, :forbidden} = Chat.room_access(stranger, room.slug)
      assert {:error, :forbidden} = Chat.room_access(nil, room.slug)
    end

    test "a denied message is an error and is not broadcast",
         %{owner: owner, stranger: stranger} do
      {:ok, room} = Chat.create_room(owner)
      Chat.subscribe(room.slug)

      assert {:error, :forbidden} = Chat.create_message(stranger, room.slug, "eve", "hi")
      refute_receive {:new_message, _message}

      assert {:ok, message, :persisted} = Chat.create_message(owner, room.slug, "ada", "hello")
      assert message.user_id == owner.user.id
      assert_receive {:new_message, %{body: "hello"}}

      assert {:error, :forbidden} = Chat.recent_messages(stranger, room.slug)
      assert {:ok, [_message]} = Chat.recent_messages(owner, room.slug)
    end

    test "share_room/3 is accounts-only and owner-only",
         %{owner: owner, member: member, stranger: stranger} do
      {:ok, room} = Chat.create_room(owner)

      assert {:error, :unknown_email} = Chat.share_room(owner, room.slug, "nobody@example.com")
      assert {:error, :not_found} = Chat.share_room(owner, room.slug, owner.user.email)
      assert {:error, :not_found} = Chat.share_room(stranger, room.slug, member.user.email)

      assert {:ok, shared} = Chat.share_room(owner, room.slug, member.user.email)
      assert shared.id == member.user.id
      assert {:error, :conflict} = Chat.share_room(owner, room.slug, member.user.email)

      assert {:ok, [listed]} = Chat.list_members(owner, room.slug)
      assert listed.user_id == member.user.id
      assert listed.email == member.user.email
    end

    test "unshare_room/3 revokes access and broadcasts it",
         %{owner: owner, member: member} do
      {:ok, room} = Chat.create_room(owner)
      {:ok, _shared} = Chat.share_room(owner, room.slug, member.user.email)
      Chat.subscribe(room.slug)

      member_id = member.user.id
      assert {:ok, 1} = Chat.unshare_room(owner, room.slug, member_id)
      assert_receive {:access_revoked, ^member_id}

      assert {:error, :forbidden} = Chat.room_access(member, room.slug)

      # Revoking someone who was not a member deletes nothing and says
      # nothing.
      assert {:ok, 0} = Chat.unshare_room(owner, room.slug, member_id)
      refute_receive {:access_revoked, _user_id}
    end

    test "leave_room/2 removes the caller's own membership",
         %{owner: owner, member: member} do
      {:ok, room} = Chat.create_room(owner)
      {:ok, _shared} = Chat.share_room(owner, room.slug, member.user.email)

      assert {:ok, 1} = Chat.leave_room(member, room.slug)
      assert {:error, :forbidden} = Chat.room_access(member, room.slug)
    end

    test "update_room/3 flips visibility, owner-only",
         %{owner: owner, stranger: stranger} do
      {:ok, room} = Chat.create_room(owner)

      assert {:error, :not_found} = Chat.update_room(stranger, room.slug, %{visibility: "link"})
      assert {:error, :forbidden} = Chat.room_access(nil, room.slug)

      assert {:ok, updated} = Chat.update_room(owner, room.slug, %{visibility: "link"})
      assert updated.visibility == "link"
      assert {:ok, %{role: :link}} = Chat.room_access(nil, room.slug)
    end

    test "delete_room/2 broadcasts and takes the transcript with it",
         %{owner: owner, stranger: stranger} do
      {:ok, room} = Chat.create_room(owner)
      {:ok, _message, :persisted} = Chat.create_message(owner, room.slug, "ada", "secret")
      Chat.subscribe(room.slug)

      assert {:error, :not_found} = Chat.delete_room(stranger, room.slug)
      refute_receive {:room_deleted}

      assert :ok = Chat.delete_room(owner, room.slug)
      assert_receive {:room_deleted}

      # The slug is unclaimed again — an empty implicit link room, not a
      # leak of the deleted room's transcript.
      assert {:ok, %{room: nil, role: :link}} = Chat.room_access(nil, room.slug)
      assert {:ok, []} = Chat.recent_messages(nil, room.slug)
    end
  end
end
