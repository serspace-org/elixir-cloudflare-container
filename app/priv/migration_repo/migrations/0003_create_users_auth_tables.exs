defmodule App.MigrationRepo.Migrations.CreateUsersAuthTables do
  @moduledoc """
  Accounts tables for `mix phx.gen.auth`, translated to D1/SQLite: no
  `citext` (unique index on `lower(email)` instead), timestamps as TEXT in
  SQLite's `CURRENT_TIMESTAMP` format, token bytes as lowercase hex. See
  the shipped `0003_create_users_auth_tables.sql` for the full rationale.

  Retrofitted from the shipped SQL — see `0001_create_tasks.exs` for why
  these early migrations execute verbatim statements.
  """

  use Ecto.Migration

  def up do
    execute """
    CREATE TABLE IF NOT EXISTS users (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      email TEXT NOT NULL CHECK (length(trim(email)) > 0 AND length(email) <= 160),
      hashed_password TEXT,
      confirmed_at TEXT,
      inserted_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
      updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
    """

    execute "CREATE UNIQUE INDEX IF NOT EXISTS users_email_idx ON users (lower(email))"

    execute """
    CREATE TABLE IF NOT EXISTS users_tokens (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL REFERENCES users (id) ON DELETE CASCADE,
      token TEXT NOT NULL CHECK (length(token) = 64),
      context TEXT NOT NULL CHECK (length(trim(context)) > 0),
      sent_to TEXT,
      authenticated_at TEXT,
      inserted_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
    """

    execute "CREATE INDEX IF NOT EXISTS users_tokens_user_id_idx ON users_tokens (user_id)"

    execute """
    CREATE UNIQUE INDEX IF NOT EXISTS users_tokens_context_token_idx
      ON users_tokens (context, token)
    """
  end

  def down do
    execute "DROP TABLE IF EXISTS users_tokens"
    execute "DROP TABLE IF EXISTS users"
  end
end
