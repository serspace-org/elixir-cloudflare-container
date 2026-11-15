defmodule AppWeb.ChatLiveTest do
  use AppWeb.ConnCase

  import App.AccountsFixtures
  import Phoenix.LiveViewTest

  alias App.Chat

  describe "shareable sessions" do
    test "joins the room named in the URL", %{conn: conn} do
      stub_d1_messages()

      {:ok, view, _html} = live(conn, ~p"/chat/standup")

      assert has_element?(view, "#share-url[value$='/chat/standup']")
    end

    test "falls back to the default room for an invalid slug", %{conn: conn} do
      stub_d1_messages()

      {:ok, view, _html} = live(conn, ~p"/chat/Bad Room")

      assert has_element?(view, "#share-url[value$='/chat/lobby']")
    end

    test "new session navigates to a fresh room, keeping the nickname", %{conn: conn} do
      stub_d1_messages()
      {:ok, view, _html} = live(conn, ~p"/chat/lobby?as=ada")

      assert {:error, {:live_redirect, %{to: to}}} =
               view |> element("#new-session") |> render_click()

      assert to =~ ~r"^/chat/[a-z0-9]+\?as=ada$"
      refute to =~ "/chat/lobby"
    end

    test "a message only reaches the room it was sent to", %{conn: conn} do
      stub_d1_messages()
      {:ok, view, _html} = live(conn, ~p"/chat/standup")

      {:ok, _message, _durability} = Chat.create_message(nil, "other-room", "ada", "wrong room")
      {:ok, _message, _durability} = Chat.create_message(nil, "standup", "ada", "right room")

      html = render(view)
      assert html =~ "right room"
      refute html =~ "wrong room"
    end

    test "renaming re-tracks presence under the new name", %{conn: conn} do
      stub_d1_messages()
      {:ok, view, _html} = live(conn, ~p"/chat/lobby?as=ada")

      assert has_element?(view, "#rename-input[value=ada]")
      assert render(view) =~ "ada"

      view |> element("#rename-form") |> render_submit(%{"nickname" => "grace"})

      assert has_element?(view, "#rename-input[value=grace]")
      assert has_element?(view, "#chat-present", "1")
    end
  end

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
    {:ok, _message, _durability} = Chat.create_message(nil, "lobby", "prober", "from the channel")

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

  describe "owned rooms" do
    setup :stub_d1_sqlite!

    test "the owner chats in their private room", %{conn: conn} do
      %{conn: conn, scope: owner} = register_and_log_in_user(%{conn: conn})
      {:ok, room} = Chat.create_room(owner)

      {:ok, view, _html} = live(conn, ~p"/chat/#{room.slug}")

      assert has_element?(view, "#share-url[value$='/chat/#{room.slug}']")
    end

    test "a logged-in stranger is bounced to the default room", %{conn: conn} do
      {:ok, room} = Chat.create_room(user_scope_fixture())
      %{conn: conn} = register_and_log_in_user(%{conn: conn})

      assert {:error, {:live_redirect, %{to: "/chat"}}} = live(conn, ~p"/chat/#{room.slug}")
    end

    test "an anonymous visitor is bounced from a private room", %{conn: conn} do
      {:ok, room} = Chat.create_room(user_scope_fixture())

      assert {:error, {:live_redirect, %{to: "/chat"}}} = live(conn, ~p"/chat/#{room.slug}")
    end

    test "a member enters, and is navigated away when revoked", %{conn: conn} do
      owner = user_scope_fixture()
      {:ok, room} = Chat.create_room(owner)
      %{conn: conn, scope: member} = register_and_log_in_user(%{conn: conn})
      {:ok, _shared} = Chat.share_room(owner, room.slug, member.user.email)

      {:ok, view, _html} = live(conn, ~p"/chat/#{room.slug}")

      {:ok, 1} = Chat.unshare_room(owner, room.slug, member.user.id)
      assert_redirect(view, "/chat")
    end
  end
end
