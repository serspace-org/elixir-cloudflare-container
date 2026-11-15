defmodule App.MigrationRepo.Migrations.CreateTasks do
  @moduledoc """
  Tasks demo table for the D1-backed CRUD LiveView.

  Retrofitted from the shipped `cloudflare/migrations/0001_create_tasks.sql`
  (this schema predates the Ecto authoring path), so it executes the same
  statements verbatim rather than using the DSL — the generated file must
  stay identical to what production already applied. Inline `CHECK`s also
  cannot be expressed through the DSL on SQLite, which has no
  `ALTER TABLE ... ADD CONSTRAINT`.
  """

  use Ecto.Migration

  def up do
    execute """
    CREATE TABLE IF NOT EXISTS tasks (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      title TEXT NOT NULL CHECK (length(trim(title)) > 0),
      completed INTEGER NOT NULL DEFAULT 0 CHECK (completed IN (0, 1)),
      inserted_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
      updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
    """
  end

  def down do
    execute "DROP TABLE IF EXISTS tasks"
  end
end
