defmodule AppWeb.ChatLiveTest do
  use AppWeb.ConnCase

  import Phoenix.LiveViewTest

  alias App.Chat

  test "renders the transport diagnostics card", %{conn: conn} do
    stub_d1_messages()

    {:ok, view, _html} = live(conn, ~p"/chat")

    assert has_element?(view, "#transport-info")
    assert has_element?(view, "#chat-form")
    assert has_element?(view, "#chat-nickname")
  end

  test "replays history from D1", %{conn: conn} do
    stub_d1_messages([
      %{"id" => 7, "room" => "lobby", "nickname" => "ada", "body" => "from history"}
    ])

    {:ok, view, _html} = live(conn, ~p"/chat")

    assert has_element?(view, "#messages-7", "from history")
  end

  test "a sent message round trips through PubSub into the stream", %{conn: conn} do
    stub_d1_messages()
    {:ok, view, _html} = live(conn, ~p"/chat")

    view
    |> element("#chat-form")
    |> render_submit(%{"body" => "hello from liveview"})

    assert render(view) =~ "hello from liveview"
  end

  test "renders a message broadcast by another client", %{conn: conn} do
    stub_d1_messages()
    {:ok, view, _html} = live(conn, ~p"/chat")

    # Stands in for the raw channel client at /probe.
    {:ok, _message, _durability} = Chat.create_message("lobby", "prober", "from the channel")

    assert render(view) =~ "from the channel"
  end

  test "rejects a blank message", %{conn: conn} do
    stub_d1_messages()
    {:ok, view, _html} = live(conn, ~p"/chat")

    view
    |> element("#chat-form")
    |> render_submit(%{"body" => "   "})

    assert has_element?(view, "#chat-error")
  end

  test "reports a degraded transport when the hook says it is not a WebSocket", %{conn: conn} do
    stub_d1_messages()
    {:ok, view, _html} = live(conn, ~p"/chat")

    html =
      render_hook(view, "transport_info", %{
        "transport" => "LongPoll",
        "websocket" => false,
        "reconnects" => 2
      })

    assert html =~ "the upgrade is failing"
  end

  test "shows an ephemeral-mode banner when D1 is unreachable", %{conn: conn} do
    stub_d1_unavailable()

    {:ok, view, _html} = live(conn, ~p"/chat")

    assert has_element?(view, "#chat-durability", "ephemeral")
  end
end
