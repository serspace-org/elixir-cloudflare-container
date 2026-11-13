defmodule AppWeb.TaskLive do
  @moduledoc """
  Task CRUD LiveView backed by Cloudflare D1 (see `App.Tasks`).
  """

  use AppWeb, :live_view

  alias App.Tasks
  alias Ecto.Changeset

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:editing_task_id, nil)
     |> load_tasks()}
  end

  def handle_event("create", %{"title" => title}, socket) do
    case Tasks.create_task(%{title: title}) do
      {:ok, task} ->
        {:noreply, assign(socket, tasks: [task | socket.assigns.tasks])}

      {:error, %Changeset{} = changeset} ->
        {:noreply, put_flash(socket, :error, changeset_message(changeset))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, d1_error_message("create"))}
    end
  end

  def handle_event("edit", %{"id" => id}, socket) do
    {:noreply, assign(socket, editing_task_id: parse_id(id))}
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, assign(socket, editing_task_id: nil)}
  end

  def handle_event("update", %{"id" => id, "title" => title}, socket) do
    case find_task(socket, id) do
      nil ->
        {:noreply, assign(socket, editing_task_id: nil)}

      task ->
        case Tasks.update_task(task, %{title: title}) do
          {:ok, updated} ->
            {:noreply,
             socket
             |> replace_task(updated)
             |> assign(editing_task_id: nil)}

          {:error, %Changeset{} = changeset} ->
            {:noreply, put_flash(socket, :error, changeset_message(changeset))}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, d1_error_message("update"))}
        end
    end
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    case find_task(socket, id) do
      nil ->
        {:noreply, socket}

      task ->
        case Tasks.toggle_task(task) do
          {:ok, updated} ->
            {:noreply, replace_task(socket, updated)}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, d1_error_message("update"))}
        end
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case find_task(socket, id) do
      nil ->
        {:noreply, socket}

      task ->
        case Tasks.delete_task(task) do
          {:ok, deleted} ->
            {:noreply,
             update(socket, :tasks, fn tasks ->
               Enum.reject(tasks, &(&1.id == deleted.id))
             end)}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, d1_error_message("delete"))}
        end
    end
  end

  ## Helpers

  defp load_tasks(socket) do
    case Tasks.list_tasks() do
      {:ok, tasks} ->
        assign(socket, tasks: tasks, d1_ready: true)

      {:error, _reason} ->
        assign(socket, tasks: [], d1_ready: false)
    end
  end

  defp find_task(socket, id) do
    id = parse_id(id)
    Enum.find(socket.assigns.tasks, &(&1.id == id))
  end

  defp parse_id(id) when is_binary(id), do: String.to_integer(id)
  defp parse_id(id) when is_integer(id), do: id

  defp replace_task(socket, updated) do
    update(socket, :tasks, fn tasks ->
      Enum.map(tasks, fn task ->
        if task.id == updated.id, do: updated, else: task
      end)
    end)
  end

  defp d1_error_message(action) do
    "Could not #{action} task: the D1 database is not configured or unreachable. " <>
      "See the database setup section in the README."
  end

  defp changeset_message(changeset) do
    messages =
      changeset
      |> Changeset.traverse_errors(fn {message, _opts} -> message end)
      |> Enum.map_join("; ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)

    if messages == "", do: "Invalid task.", else: "Invalid task: " <> messages
  end
end
