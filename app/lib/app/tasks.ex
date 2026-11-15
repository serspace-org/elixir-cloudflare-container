defmodule App.Tasks do
  @moduledoc """
  Task CRUD backed by Cloudflare D1 through the Worker's private gateway.

  D1 is not an Ecto repo, so `App.Tasks.Task` is an embedded schema used
  for validation only; persistence goes through `App.D1`.

  Every function takes an `App.Accounts.Scope` as its first argument and acts
  only on that user's tasks. The scope is matched, not merely read, so a
  missing user raises here rather than quietly reaching for someone else's
  rows — and the `user_id` it carries is bound into the SQL by the gateway,
  which is where ownership is actually enforced. A task belonging to another
  user is a `{:error, :not_found}`, indistinguishable from one that never
  existed.
  """

  alias App.Accounts.Scope
  alias App.D1
  alias App.Tasks.Task
  alias Ecto.Changeset

  @doc "Returns the scope's tasks, newest first."
  @spec list_tasks(Scope.t()) :: {:ok, [Task.t()]} | {:error, term()}
  def list_tasks(%Scope{user: %{id: user_id}}) do
    with {:ok, rows} <- D1.list_tasks(user_id) do
      {:ok, Enum.map(rows, &to_task/1)}
    end
  end

  @doc "Returns the scope's task with the given id."
  @spec get_task(Scope.t(), integer() | String.t()) :: {:ok, Task.t()} | {:error, term()}
  def get_task(%Scope{user: %{id: user_id}}, id) do
    with {:ok, row} <- D1.get_task(user_id, id) do
      {:ok, to_task(row)}
    end
  end

  @doc "Creates a task owned by the scope's user."
  @spec create_task(Scope.t(), map()) :: {:ok, Task.t()} | {:error, Changeset.t() | term()}
  def create_task(%Scope{user: %{id: user_id}}, attrs) do
    %Task{}
    |> Task.changeset(attrs)
    |> Changeset.apply_action(:insert)
    |> case do
      {:ok, %{title: title}} ->
        with {:ok, row} <- D1.create_task(user_id, title) do
          {:ok, to_task(row)}
        end

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc "Updates one of the scope's tasks with the given attributes."
  @spec update_task(Scope.t(), Task.t(), map()) ::
          {:ok, Task.t()} | {:error, Changeset.t() | term()}
  def update_task(%Scope{user: %{id: user_id}}, %Task{user_id: user_id} = task, attrs) do
    task
    |> Task.changeset(attrs)
    |> Changeset.apply_action(:update)
    |> case do
      {:ok, %{title: title, completed: completed}} ->
        with {:ok, row} <-
               D1.update_task(user_id, task.id, %{title: title, completed: completed}) do
          {:ok, to_task(row)}
        end

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc "Flips the completed flag on one of the scope's tasks."
  @spec toggle_task(Scope.t(), Task.t()) :: {:ok, Task.t()} | {:error, term()}
  def toggle_task(%Scope{} = scope, %Task{} = task) do
    update_task(scope, task, %{completed: not task.completed})
  end

  @doc "Deletes one of the scope's tasks. Deleting a missing task succeeds."
  @spec delete_task(Scope.t(), Task.t()) :: {:ok, Task.t()} | {:error, term()}
  def delete_task(%Scope{user: %{id: user_id}}, %Task{user_id: user_id} = task) do
    case D1.delete_task(user_id, task.id) do
      :ok -> {:ok, task}
      {:error, :not_found} -> {:ok, task}
      {:error, _reason} = error -> error
    end
  end

  ## Row conversion

  defp to_task(row) do
    %Task{
      id: row["id"],
      user_id: row["user_id"],
      title: row["title"],
      completed: row["completed"] in [1, true],
      inserted_at: parse_timestamp(row["inserted_at"]),
      updated_at: parse_timestamp(row["updated_at"])
    }
  end

  defp parse_timestamp(nil), do: nil

  defp parse_timestamp(timestamp) when is_binary(timestamp) do
    case NaiveDateTime.from_iso8601(timestamp) do
      {:ok, parsed} -> parsed
      {:error, _reason} -> nil
    end
  end
end
