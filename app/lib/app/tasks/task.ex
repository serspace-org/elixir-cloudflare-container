defmodule App.Tasks.Task do
  @moduledoc """
  An Ecto embedded schema for tasks.

  Used for casting and validation only. Rows live in Cloudflare D1 and are
  persisted through the private gateway in `App.D1` — there is no Repo.
  """

  use Ecto.Schema
  import Ecto.Changeset

  # Integer ids come from D1 (AUTOINCREMENT); Ecto only supports
  # autogenerate: true for :binary_id primary keys, so we declare the
  # primary key without it.
  @primary_key {:id, :integer, []}
  embedded_schema do
    field :title, :string
    field :completed, :boolean, default: false
    field :inserted_at, :naive_datetime
    field :updated_at, :naive_datetime
  end

  @doc "Casts and validates task attributes."
  def changeset(task, attrs) do
    task
    |> cast(attrs, [:title, :completed])
    |> update_change(:title, &String.trim/1)
    |> validate_required([:title])
    |> validate_length(:title, min: 1, max: 255)
  end
end
