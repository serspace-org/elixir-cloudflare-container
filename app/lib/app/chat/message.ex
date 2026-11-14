defmodule App.Chat.Message do
  @moduledoc """
  An Ecto embedded schema for chat messages.

  Used for casting and validation only. Rows live in Cloudflare D1 and are
  persisted through the private gateway in `App.D1` — there is no Repo.
  """

  use Ecto.Schema
  import Ecto.Changeset

  # Integer ids come from D1 (AUTOINCREMENT); see App.Tasks.Task for why
  # the primary key is declared without autogenerate.
  @primary_key {:id, :integer, []}
  embedded_schema do
    field :room, :string
    field :nickname, :string
    field :body, :string
    field :inserted_at, :naive_datetime
  end

  @doc "Casts and validates message attributes."
  def changeset(message, attrs) do
    message
    |> cast(attrs, [:room, :nickname, :body])
    |> update_change(:room, &String.trim/1)
    |> update_change(:nickname, &String.trim/1)
    |> update_change(:body, &String.trim/1)
    |> validate_required([:room, :nickname, :body])
    |> validate_length(:room, min: 1, max: 64)
    |> validate_length(:nickname, min: 1, max: 64)
    |> validate_length(:body, min: 1, max: 2000)
  end
end
