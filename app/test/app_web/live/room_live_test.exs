defmodule AppWeb.RoomLiveTest do
  use AppWeb.ConnCase

  import App.AccountsFixtures
  import Phoenix.LiveViewTest

  alias App.Chat

  # Room authorization is SQL in the gateway, so everything here runs
  # against the sqlite-backed stub.
  setup :stub_d1_sqlite!

  test "requires an account", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/rooms")
  end

  describe "when logged in" do
    setup :register_and_log_in_user

    test "creates a room and lists it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/rooms")

      html =
        view
        |> form("form[phx-submit=create]", %{name: "Standup", visibility: "private"})
        |> render_submit()

      assert html =~ "Standup"
      assert html =~ "private"
    end

    test "toggles visibility", %{conn: conn, scope: scope} do
      {:ok, room} = Chat.create_room(scope, %{name: "Standup"})
      {:ok, view, _html} = live(conn, ~p"/rooms")

      html =
        view
        |> element("#room-#{room.slug} button", "Make link-open")
        |> render_click()

      assert html =~ "link-open"
      assert {:ok, %{role: :link}} = Chat.room_access(nil, room.slug)
    end

    test "shares with an existing account and revokes", %{conn: conn, scope: scope} do
      {:ok, room} = Chat.create_room(scope)
      member = user_fixture()
      {:ok, view, _html} = live(conn, ~p"/rooms")

      view |> element("#room-#{room.slug} button", "Share") |> render_click()

      html =
        view
        |> form("#share-#{room.slug} form[phx-submit=share]", %{email: member.email})
        |> render_submit()

      assert html =~ member.email

      assert {:ok, %{role: :member}} =
               Chat.room_access(App.Accounts.Scope.for_user(member), room.slug)

      html =
        view
        |> element("#share-#{room.slug} button", "Revoke")
        |> render_click()

      refute html =~ member.email

      assert {:error, :forbidden} =
               Chat.room_access(App.Accounts.Scope.for_user(member), room.slug)
    end

    test "flashes on an email with no account", %{conn: conn, scope: scope} do
      {:ok, room} = Chat.create_room(scope)
      {:ok, view, _html} = live(conn, ~p"/rooms")

      view |> element("#room-#{room.slug} button", "Share") |> render_click()

      html =
        view
        |> form("#share-#{room.slug} form[phx-submit=share]", %{email: "nobody@example.com"})
        |> render_submit()

      assert html =~ "No account with that email"
    end

    test "a member sees the shared room and can leave it", %{conn: conn, scope: scope} do
      owner = user_scope_fixture()
      {:ok, room} = Chat.create_room(owner, %{name: "Theirs"})
      {:ok, _shared} = Chat.share_room(owner, room.slug, scope.user.email)

      {:ok, view, html} = live(conn, ~p"/rooms")
      assert html =~ "Theirs"
      assert html =~ "shared with you"

      html = view |> element("#room-#{room.slug} button", "Leave") |> render_click()
      refute html =~ "Theirs"
      assert {:error, :forbidden} = Chat.room_access(scope, room.slug)
    end

    test "deletes a room", %{conn: conn, scope: scope} do
      {:ok, room} = Chat.create_room(scope, %{name: "Doomed"})
      {:ok, view, html} = live(conn, ~p"/rooms")
      assert html =~ "Doomed"

      html = view |> element("#room-#{room.slug} button", "Delete") |> render_click()
      refute html =~ "Doomed"
      assert {:ok, %{room: nil, role: :link}} = Chat.room_access(scope, room.slug)
    end
  end
end
