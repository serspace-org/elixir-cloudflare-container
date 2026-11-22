defmodule AppWeb.RoomLive do
  @moduledoc """
  Management UI for owned and shared chat rooms (see `App.Chat`).

  Mounted in the `:require_authenticated_user` live session, so
  `@current_scope.user` is always present. Anonymous chat never needs this
  page — link rooms are entered straight through `/chat/:room` — which is
  why `/chat` stays open while `/rooms` requires an account.
  """

  use AppWeb, :live_view

  alias App.Chat
  alias Ecto.Changeset

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(sharing_slug: nil, members: [])
     |> load_rooms()}
  end

  def handle_event("create", %{"name" => name, "visibility" => visibility}, socket) do
    case Chat.create_room(scope(socket), %{name: name, visibility: visibility}) do
      {:ok, room} ->
        {:noreply, update(socket, :rooms, &[room | &1])}

      {:error, %Changeset{} = changeset} ->
        {:noreply, put_flash(socket, :error, changeset_message(changeset))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, d1_error_message("create"))}
    end
  end

  def handle_event("toggle_visibility", %{"slug" => slug}, socket) do
    case find_room(socket, slug) do
      %{role: :owner} = room ->
        next = if room.visibility == "private", do: "link", else: "private"

        case Chat.update_room(scope(socket), slug, %{name: room.name, visibility: next}) do
          {:ok, updated} ->
            {:noreply, replace_room(socket, updated)}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, d1_error_message("update"))}
        end

      _other ->
        {:noreply, socket}
    end
  end

  def handle_event("delete", %{"slug" => slug}, socket) do
    case Chat.delete_room(scope(socket), slug) do
      :ok ->
        {:noreply,
         socket
         |> remove_room(slug)
         |> close_share_panel(slug)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, d1_error_message("delete"))}
    end
  end

  def handle_event("leave", %{"slug" => slug}, socket) do
    case Chat.leave_room(scope(socket), slug) do
      {:ok, _count} ->
        {:noreply, remove_room(socket, slug)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, d1_error_message("leave"))}
    end
  end

  def handle_event("share_panel", %{"slug" => slug}, socket) do
    {:noreply, socket |> assign(sharing_slug: slug) |> load_members(slug)}
  end

  def handle_event("close_share", _params, socket) do
    {:noreply, assign(socket, sharing_slug: nil, members: [])}
  end

  def handle_event("share", %{"slug" => slug, "email" => email}, socket) do
    case Chat.share_room(scope(socket), slug, String.trim(email)) do
      {:ok, _member} ->
        {:noreply, load_members(socket, slug)}

      {:error, :unknown_email} ->
        # Accounts-only on purpose: there is no invitation email (see
        # App.Chat.share_room/3); link visibility is the escape hatch.
        {:noreply,
         put_flash(
           socket,
           :error,
           "No account with that email. Sharing works with existing accounts only — " <>
             "or make the room link-open and send the link."
         )}

      {:error, :conflict} ->
        {:noreply, put_flash(socket, :error, "This room is already shared with them.")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "You can only share your own rooms with others.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, d1_error_message("share"))}
    end
  end

  def handle_event("revoke", %{"slug" => slug, "user-id" => user_id}, socket) do
    case Chat.unshare_room(scope(socket), slug, String.to_integer(user_id)) do
      {:ok, _count} ->
        {:noreply, load_members(socket, slug)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, d1_error_message("revoke"))}
    end
  end

  ## Helpers

  defp scope(socket), do: socket.assigns.current_scope

  defp load_rooms(socket) do
    case Chat.list_rooms(scope(socket)) do
      {:ok, rooms} -> assign(socket, rooms: rooms, d1_ready: true)
      {:error, _reason} -> assign(socket, rooms: [], d1_ready: false)
    end
  end

  defp load_members(socket, slug) do
    case Chat.list_members(scope(socket), slug) do
      {:ok, members} -> assign(socket, members: members)
      {:error, _reason} -> assign(socket, members: [])
    end
  end

  defp find_room(socket, slug) do
    Enum.find(socket.assigns.rooms, &(&1.slug == slug))
  end

  defp replace_room(socket, updated) do
    update(socket, :rooms, fn rooms ->
      Enum.map(rooms, fn room ->
        if room.slug == updated.slug, do: updated, else: room
      end)
    end)
  end

  defp remove_room(socket, slug) do
    update(socket, :rooms, fn rooms -> Enum.reject(rooms, &(&1.slug == slug)) end)
  end

  defp close_share_panel(socket, slug) do
    if socket.assigns.sharing_slug == slug do
      assign(socket, sharing_slug: nil, members: [])
    else
      socket
    end
  end

  defp d1_error_message(action) do
    "Could not #{action} room: the D1 database is not configured or unreachable. " <>
      "See the database section of docs/setup.md."
  end

  defp changeset_message(changeset) do
    messages =
      changeset
      |> Changeset.traverse_errors(fn {message, _opts} -> message end)
      |> Enum.map_join("; ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)

    if messages == "", do: "Invalid room.", else: "Invalid room: " <> messages
  end
end
