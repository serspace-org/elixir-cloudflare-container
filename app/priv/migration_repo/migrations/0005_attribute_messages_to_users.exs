defmodule App.MigrationRepo.Migrations.AttributeMessagesToUsers do
  @moduledoc """
  Attributes a chat message to the account that sent it. Nullable because
  it is additive — the previous version keeps serving during a rolling
  deploy, so rows written before it have a NULL owner; `ON DELETE SET NULL`
  so deleting an account doesn't punch holes in a conversation other people
  are still reading.

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
