defmodule App.MigrationRepo.Migrations.ScopeTasksToUsers do
  @moduledoc """
  Scopes tasks to the user who owns them. Nullable on purpose: additive, so
  the previous app version keeps serving during a deploy; pre-migration
  rows have a NULL owner and are invisible rather than shared.

  Retrofitted from the shipped SQL — see `0001_create_tasks.exs` for why
  these early migrations execute verbatim statements.
  """

  use Ecto.Migration

  def up do
    execute """
    ALTER TABLE tasks ADD COLUMN user_id INTEGER REFERENCES users (id) ON DELETE CASCADE
    """

    execute """
    CREATE INDEX IF NOT EXISTS tasks_user_id_idx ON tasks (user_id, inserted_at DESC, id DESC)
    """
  end

  def down do
    execute "DROP INDEX IF EXISTS tasks_user_id_idx"
    execute "ALTER TABLE tasks DROP COLUMN user_id"
  end
end
