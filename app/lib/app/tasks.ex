defmodule App.Tasks do
  @moduledoc """
  Task CRUD backed by Cloudflare D1 through the Worker's private gateway.

  D1 is not an Ecto repo, so `App.Tasks.Task` is an embedded schema used
  for validation only; persistence goes through `App.D1`.
  """

  alias App.D1
  alias App.Tasks.Task
  alias Ecto.Changeset

  @doc "Returns all tasks, newest first."
  @spec list_tasks() :: {:ok, [Task.t()]} | {:error, term()}
  def list_tasks do
    with {:ok, rows} <- D1.list_tasks() do
      {:ok, Enum.map(rows, &to_task/1)}
    end
  end

  @doc "Returns the task with the given id."
  @spec get_task(integer() | String.t()) :: {:ok, Task.t()} | {:error, term()}
  def get_task(id) do
    with {:ok, row} <- D1.get_task(id) do
      {:ok, to_task(row)}
    end
  end

  @doc "Creates a task."
  @spec create_task(map()) :: {:ok, Task.t()} | {:error, Changeset.t() | term()}
  def create_task(attrs) do
    %Task{}
    |> Task.changeset(attrs)
    |> Changeset.apply_action(:insert)
    |> case do
      {:ok, %{title: title}} ->
        with {:ok, row} <- D1.create_task(title) do
          {:ok, to_task(row)}
        end

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc "Updates a task with the given attributes."
  @spec update_task(Task.t(), map()) :: {:ok, Task.t()} | {:error, Changeset.t() | term()}
  def update_task(%Task{} = task, attrs) do
    task
    |> Task.changeset(attrs)
    |> Changeset.apply_action(:update)
    |> case do
      {:ok, %{title: title, completed: completed}} ->
        with {:ok, row} <- D1.update_task(task.id, %{title: title, completed: completed}) do
          {:ok, to_task(row)}
        end

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc "Flips a task's completed flag."
  @spec toggle_task(Task.t()) :: {:ok, Task.t()} | {:error, term()}
  def toggle_task(%Task{} = task) do
    update_task(task, %{completed: not task.completed})
  end

  @doc "Deletes a task. Deleting a missing task succeeds."
  @spec delete_task(Task.t()) :: {:ok, Task.t()} | {:error, term()}
  def delete_task(%Task{} = task) do
    case D1.delete_task(task.id) do
      :ok -> {:ok, task}
      {:error, :not_found} -> {:ok, task}
      {:error, _reason} = error -> error
    end
  end

  ## Row conversion

  defp to_task(row) do
    %Task{
      id: row["id"],
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
