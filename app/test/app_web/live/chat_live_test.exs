defmodule AppWeb.ChatLiveTest do
  @moduledoc """
  `/chat` requires a logged-in user and sends as that account.

  Backed by the SQLite stub rather than an in-memory message store, because
  the session's user has to be readable through the same gateway the
  messages go through.
  """

  # Not async: the stub is resolved in shared mode, because the D1 calls come
  # from the LiveView process rather than the test process. See App.D1Stub.
  use AppWeb.ConnCase, async: false

  import App.AccountsFixtures
  import Phoenix.LiveViewTest
  import App.AccountsFixtures

  alias App.Accounts.Scope
  alias App.Chat

  describe "a visitor" do
    setup :stub_d1_sqlite!

    test "is redirected to the log-in page", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/users/log-in", flash: flash}}} = live(conn, ~p"/chat")
      assert flash["error"] == "You must log in to access this page."
    end

    test "is redirected away from a shared room too", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/chat/standup")
    end
  end

  describe "logged in" do
    setup [:stub_d1_sqlite!, :register_and_log_in_user]

    test "sends as the account, not as a name from the client", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      assert has_element?(view, "#chat-nickname", Chat.sender_name(scope))

      view |> element("#chat-form") |> render_submit(%{"body" => "hello from liveview"})

      assert {:ok, [message]} = Chat.recent_messages(scope, "lobby")
      assert message.user_id == scope.user.id
      assert message.nickname == Chat.sender_name(scope)
      assert render(view) =~ "hello from liveview"
    end

    test "labels its own messages and names everyone else's", %{conn: conn, scope: scope} do
      other = Scope.for_user(user_fixture())
      {:ok, _message, _durability} = Chat.create_message(other, "lobby", "from the channel")
      {:ok, _message, _durability} = Chat.create_message(scope, "lobby", "mine")

      {:ok, _view, html} = live(conn, ~p"/chat")

      assert html =~ "You"
      assert html =~ Chat.sender_name(other)
      assert html =~ "from the channel"
      assert html =~ "mine"
    end

    test "lists who is in the room", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      assert has_element?(view, "#chat-present", "1")
      assert render(view) =~ Chat.sender_name(scope)
    end

    test "renders the transport diagnostics card", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      assert has_element?(view, "#transport-info")
      assert has_element?(view, "#chat-form")
      assert has_element?(view, "#chat-nickname")
    end

    test "replays history from D1", %{conn: conn, scope: scope} do
      {:ok, message, :persisted} = Chat.create_message(scope, "lobby", "from history")

      {:ok, view, _html} = live(conn, ~p"/chat")

      assert has_element?(view, "#messages-#{message.id}", "from history")
    end

    test "renders a message broadcast by another client", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      # Stands in for the raw channel client at /probe.
      other = Scope.for_user(user_fixture())
      {:ok, _message, _durability} = Chat.create_message(other, "lobby", "from the channel")

      assert render(view) =~ "from the channel"
    end

    test "rejects a blank message", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      view |> element("#chat-form") |> render_submit(%{"body" => "   "})

      assert has_element?(view, "#chat-error")
    end

    test "reports a degraded transport when the hook says it is not a WebSocket",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      html =
        render_hook(view, "transport_info", %{
          "transport" => "LongPoll",
          "websocket" => false,
          "reconnects" => 2
        })

      assert html =~ "the upgrade is failing"
    end
  end

  describe "shareable sessions" do
    setup [:stub_d1_sqlite!, :register_and_log_in_user]

    test "joins the room named in the URL", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat/standup")

      assert has_element?(view, "#share-url[value$='/chat/standup']")
    end

    test "falls back to the default room for an invalid slug", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat/Bad Room")

      assert has_element?(view, "#share-url[value$='/chat/lobby']")
    end

    test "new session navigates to a fresh room", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat/lobby")

      assert {:error, {:live_redirect, %{to: to}}} =
               view |> element("#new-session") |> render_click()

      assert to =~ ~r"^/chat/[a-z0-9]+$"
      refute to =~ "/chat/lobby"
    end

    test "a message only reaches the room it was sent to", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/chat/standup")

      {:ok, _message, _durability} = Chat.create_message(scope, "other-room", "wrong room")
      {:ok, _message, _durability} = Chat.create_message(scope, "standup", "right room")

      html = render(view)
      assert html =~ "right room"
      refute html =~ "wrong room"
    end
  end

  describe "with the message routes unreachable" do
    setup [:stub_d1_sqlite_without_chat!, :register_and_log_in_user]

    test "stays usable and says it is ephemeral", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      assert has_element?(view, "#chat-durability", "ephemeral")

      view |> element("#chat-form") |> render_submit(%{"body" => "no database here"})
      assert render(view) =~ "no database here"
    end
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
