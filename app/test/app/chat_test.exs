defmodule App.ChatTest do
  use ExUnit.Case

  import App.D1Stub

  alias App.Chat

  setup tags do
    Req.Test.set_req_test_from_context(tags)
    :ok
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
