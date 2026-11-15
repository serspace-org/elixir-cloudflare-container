defmodule App.TasksTest do
  @moduledoc """
  Scoping tests for `App.Tasks`.

  Backed by a real SQLite database (`App.D1Stub.stub_d1_sqlite!/1`) rather
  than hand-written stubs, because what is under test is SQL the gateway has
  to actually run: the `user_id` bound alongside the id in every statement.
  A hand-written stub would be free to answer whatever we asked of it.
  """

  # Not async: the stub is resolved in shared mode; see App.D1Stub.
  use App.DataCase, async: false

  import App.AccountsFixtures

  alias App.Tasks
  alias App.Tasks.Task

  setup :stub_d1_sqlite!

  setup do
    %{scope: user_scope_fixture(), other_scope: user_scope_fixture()}
  end

  describe "create_task/2" do
    test "owns the task it creates", %{scope: scope} do
      assert {:ok, %Task{} = task} = Tasks.create_task(scope, %{title: "write it down"})
      assert task.user_id == scope.user.id
      assert task.title == "write it down"
      refute task.completed
    end

    test "validates the title", %{scope: scope} do
      assert {:error, changeset} = Tasks.create_task(scope, %{title: "   "})
      assert %{title: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "list_tasks/1" do
    test "returns only the scope's tasks", %{scope: scope, other_scope: other_scope} do
      {:ok, mine} = Tasks.create_task(scope, %{title: "mine"})
      {:ok, _theirs} = Tasks.create_task(other_scope, %{title: "theirs"})

      assert {:ok, [listed]} = Tasks.list_tasks(scope)
      assert listed.id == mine.id

      assert {:ok, [other]} = Tasks.list_tasks(other_scope)
      assert other.title == "theirs"
    end
  end

  describe "get_task/2" do
    test "does not reach another user's task", %{scope: scope, other_scope: other_scope} do
      {:ok, task} = Tasks.create_task(scope, %{title: "mine"})

      assert {:ok, %Task{}} = Tasks.get_task(scope, task.id)
      assert {:error, :not_found} = Tasks.get_task(other_scope, task.id)
    end
  end

  describe "update_task/3 and toggle_task/2" do
    test "update the scope's own task", %{scope: scope} do
      {:ok, task} = Tasks.create_task(scope, %{title: "mine"})

      assert {:ok, renamed} = Tasks.update_task(scope, task, %{title: "renamed"})
      assert renamed.title == "renamed"
      assert renamed.user_id == scope.user.id

      assert {:ok, toggled} = Tasks.toggle_task(scope, renamed)
      assert toggled.completed
    end

    test "refuse a task owned by someone else", %{scope: scope, other_scope: other_scope} do
      {:ok, task} = Tasks.create_task(scope, %{title: "mine"})

      assert_raise FunctionClauseError, fn ->
        Tasks.update_task(other_scope, task, %{title: "stolen"})
      end

      assert_raise FunctionClauseError, fn -> Tasks.toggle_task(other_scope, task) end

      assert {:ok, unchanged} = Tasks.get_task(scope, task.id)
      assert unchanged.title == "mine"
      refute unchanged.completed
    end
  end

  describe "delete_task/2" do
    test "deletes the scope's own task", %{scope: scope} do
      {:ok, task} = Tasks.create_task(scope, %{title: "mine"})

      assert {:ok, _deleted} = Tasks.delete_task(scope, task)
      assert {:ok, []} = Tasks.list_tasks(scope)
    end

    test "refuses a task owned by someone else", %{scope: scope, other_scope: other_scope} do
      {:ok, task} = Tasks.create_task(scope, %{title: "mine"})

      assert_raise FunctionClauseError, fn -> Tasks.delete_task(other_scope, task) end
      assert {:ok, [_task]} = Tasks.list_tasks(scope)
    end
  end
end
