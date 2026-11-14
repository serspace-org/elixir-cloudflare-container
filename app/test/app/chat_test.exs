defmodule App.ChatTest do
  use ExUnit.Case

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

      assert {:ok, _message, :persisted} = Chat.create_message("two", "ada", "elsewhere")
      refute_receive {:new_message, _message}

      assert {:ok, _message, :persisted} = Chat.create_message("one", "ada", "here")
      assert_receive {:new_message, %{body: "here"}}
    end
  end

  test "create_message/3 broadcasts on the chat topic, not the channel topic" do
    stub_d1_messages()
    Chat.subscribe("lobby")
    # The channel topic; a broadcast here would double-deliver to channels.
    Phoenix.PubSub.subscribe(App.PubSub, "room:lobby")

    assert {:ok, message, :persisted} = Chat.create_message("lobby", "ada", "hi")
    assert message.id == 1

    assert_receive {:new_message, %{body: "hi"}}
    refute_receive {:new_message, _message}
  end

  test "create_message/3 trims and validates" do
    stub_d1_messages()

    assert {:error, changeset} = Chat.create_message("lobby", "ada", "  ")
    refute changeset.valid?
  end

  test "create_message/3 degrades to ephemeral without D1" do
    stub_d1_unavailable()

    assert {:ok, message, :ephemeral} = Chat.create_message("lobby", "ada", "hi")
    assert message.id
    assert message.inserted_at
  end

  test "recent_messages/2 surfaces gateway failures" do
    stub_d1_unavailable()

    assert {:error, :gateway_unreachable} = Chat.recent_messages("lobby")
  end
end
