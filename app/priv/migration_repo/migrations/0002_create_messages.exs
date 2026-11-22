defmodule App.MigrationRepo.Migrations.CreateMessages do
  @moduledoc """
  Chat demo table backing the WebSocket/Channel smoke test; history is
  persisted so a reconnect or container restart can be told apart from
  message loss.

  Retrofitted from the shipped SQL — see `0001_create_tasks.exs` for why
  these early migrations execute verbatim statements.
  """

  use Ecto.Migration

  def up do
    execute """
    CREATE TABLE IF NOT EXISTS messages (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      room TEXT NOT NULL CHECK (length(trim(room)) > 0),
      nickname TEXT NOT NULL CHECK (length(trim(nickname)) > 0),
      body TEXT NOT NULL CHECK (length(trim(body)) > 0),
      inserted_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
    """

    execute "CREATE INDEX IF NOT EXISTS messages_room_id_idx ON messages (room, id)"
  end

  def down do
    execute "DROP TABLE IF EXISTS messages"
  end
end
