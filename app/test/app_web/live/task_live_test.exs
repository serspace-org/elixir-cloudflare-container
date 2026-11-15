defmodule AppWeb.TaskLiveTest do
  @moduledoc """
  `/tasks` requires a logged-in user and shows only that user's tasks.
  """

  # Not async: the stub is resolved in shared mode, because the D1 calls come
  # from the LiveView process rather than the test process. See App.D1Stub.
  use AppWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import App.AccountsFixtures

  alias App.Accounts.Scope
  alias App.Tasks

  setup :stub_d1_sqlite!

  test "redirects a visitor to the log-in page", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/users/log-in", flash: flash}}} = live(conn, ~p"/tasks")
    assert flash["error"] == "You must log in to access this page."
  end

  describe "logged in" do
    setup :register_and_log_in_user

    test "lists only the current user's tasks", %{conn: conn, scope: scope} do
      {:ok, _mine} = Tasks.create_task(scope, %{title: "mine"})
      {:ok, _theirs} = Tasks.create_task(Scope.for_user(user_fixture()), %{title: "theirs"})

      {:ok, _live, html} = live(conn, ~p"/tasks")

      assert html =~ "mine"
      refute html =~ "theirs"
      assert html =~ scope.user.email
    end

    test "creates, toggles, edits and deletes a task of its own", %{conn: conn, scope: scope} do
      {:ok, live, _html} = live(conn, ~p"/tasks")

      assert live |> form("form[phx-submit=create]", %{title: "write it down"}) |> render_submit() =~
               "write it down"

      assert {:ok, [task]} = Tasks.list_tasks(scope)
      assert task.user_id == scope.user.id

      live |> element("input[phx-click=toggle]") |> render_click()
      assert {:ok, [toggled]} = Tasks.list_tasks(scope)
      assert toggled.completed

      live |> element("button[phx-click=edit]") |> render_click()

      assert live
             |> form("form[phx-submit=update]", %{title: "renamed"})
             |> render_submit() =~ "renamed"

      live |> element("button[phx-click=delete]") |> render_click()
      assert {:ok, []} = Tasks.list_tasks(scope)
    end
  end
end
