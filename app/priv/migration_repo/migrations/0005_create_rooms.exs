defmodule App.MigrationRepo.Migrations.CreateRooms do
  @moduledoc """
  Rooms become rows so a chat can belong to a user and be shared. A room
  with *no* row stays an implicit link room (anyone with the slug — the
  pre-rooms behavior), which is why there is no backfill. See the shipped
  `0005_create_rooms.sql` for the full rationale.

  Retrofitted from the shipped SQL — see `0001_create_tasks.exs` for why
  these early migrations execute verbatim statements.
  """

  use Ecto.Migration

  def up do
    execute """
    CREATE TABLE IF NOT EXISTS rooms (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      slug TEXT NOT NULL CHECK (length(trim(slug)) > 0 AND length(slug) <= 64),
      user_id INTEGER NOT NULL REFERENCES users (id) ON DELETE CASCADE,
      name TEXT CHECK (name IS NULL OR (length(trim(name)) > 0 AND length(name) <= 160)),
      visibility TEXT NOT NULL DEFAULT 'link' CHECK (visibility IN ('link', 'private')),
      inserted_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
      updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
    """

    execute "CREATE UNIQUE INDEX IF NOT EXISTS rooms_slug_idx ON rooms (slug)"

    execute """
    CREATE INDEX IF NOT EXISTS rooms_user_id_idx ON rooms (user_id, inserted_at DESC, id DESC)
    """

    execute """
    CREATE TABLE IF NOT EXISTS room_memberships (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      room_id INTEGER NOT NULL REFERENCES rooms (id) ON DELETE CASCADE,
      user_id INTEGER NOT NULL REFERENCES users (id) ON DELETE CASCADE,
      inserted_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
    """

    execute """
    CREATE UNIQUE INDEX IF NOT EXISTS room_memberships_room_user_idx
      ON room_memberships (room_id, user_id)
    """

    execute """
    CREATE INDEX IF NOT EXISTS room_memberships_user_idx
      ON room_memberships (user_id, room_id)
    """
  end

  def down do
    execute "DROP TABLE IF EXISTS room_memberships"
    execute "DROP TABLE IF EXISTS rooms"
  end
end
