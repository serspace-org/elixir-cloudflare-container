defmodule App.ChatTest do
  use ExUnit.Case

  import App.D1Stub

  alias App.Accounts.Scope
  alias App.Accounts.User
  alias App.Chat

  setup tags do
    Req.Test.set_req_test_from_context(tags)
    :ok
  end

  # The sender only has to be a user as far as `App.Chat` is concerned — it
  # takes the id and the display name off the scope and never reads a row —
  # so these stay away from the accounts context and its SQLite stub. A scope
  # without a user has no test: `create_message/3` and `sender_name/1` match
  # `%Scope{user: %User{}}`, so passing one is a compile-time type error now,
  # which is a stronger guarantee than a raise assertion.
  defp scope(id \\ 1, email \\ "ada@example.com") do
    Scope.for_user(%User{id: id, email: email})
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

      assert {:ok, _message, :persisted} = Chat.create_message(scope(), "two", "elsewhere")
      refute_receive {:new_message, _message}

      assert {:ok, _message, :persisted} = Chat.create_message(scope(), "one", "here")
      assert_receive {:new_message, %{body: "here"}}
    end
  end

  test "sender_name/1 is the email's local part" do
    assert Chat.sender_name(scope(1, "ada@example.com")) == "ada"
  end

  describe "create_message/3" do
    test "attributes the message to the scope's user" do
      store = stub_d1_messages()

      assert {:ok, message, :persisted} =
               Chat.create_message(scope(42, "grace@example.com"), "lobby", "hi")

      assert message.user_id == 42
      assert message.nickname == "grace"

      assert [%{"user_id" => 42, "nickname" => "grace"}] = persisted_messages(store)
    end

    test "broadcasts on the chat topic, not the channel topic" do
      stub_d1_messages()
      Chat.subscribe("lobby")
      # The channel topic; a broadcast here would double-deliver to channels.
      Phoenix.PubSub.subscribe(App.PubSub, "room:lobby")

      assert {:ok, message, :persisted} = Chat.create_message(scope(), "lobby", "hi")
      assert message.id == 1

      assert_receive {:new_message, %{body: "hi"}}
      refute_receive {:new_message, _message}
    end

    test "trims and validates" do
      stub_d1_messages()

      assert {:error, changeset} = Chat.create_message(scope(), "lobby", "  ")
      refute changeset.valid?
    end

    test "degrades to ephemeral without D1" do
      stub_d1_unavailable()

      assert {:ok, message, :ephemeral} = Chat.create_message(scope(), "lobby", "hi")
      assert message.id
      assert message.inserted_at
      assert message.user_id == 1
    end
  end

  test "recent_messages/2 surfaces gateway failures" do
    stub_d1_unavailable()

    assert {:error, :gateway_unreachable} = Chat.recent_messages("lobby")
  end
end
