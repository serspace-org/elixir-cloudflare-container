defmodule App.MigrationRepo.Migrations.AttributeMessagesToUsers do
  @moduledoc """
  Attributes a message to the account that sent it, when there was one.
  Nullable (anonymous senders in link rooms; additive for the rolling
  deploy); `ON DELETE SET NULL` so deleting an account doesn't rewrite
  other people's transcripts.

  Retrofitted from the shipped SQL — see `0001_create_tasks.exs` for why
  these early migrations execute verbatim statements.
  """

  use Ecto.Migration

  def up do
    execute """
    ALTER TABLE messages ADD COLUMN user_id INTEGER REFERENCES users (id) ON DELETE SET NULL
    """
  end

  def down do
    execute "ALTER TABLE messages DROP COLUMN user_id"
  end
end
