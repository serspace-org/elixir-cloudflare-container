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
    field :user_id, :integer
    field :nickname, :string
    field :body, :string
    field :inserted_at, :naive_datetime
  end

  @doc """
  Casts and validates message attributes.

  `user_id` and `nickname` are deliberately absent from `cast/3`: they are
  the sender's identity, set from the `App.Accounts.Scope` in
  `App.Chat.create_message/3`, and casting them would let a client label a
  message with someone else's account. They are still validated, so a
  message built without a sender fails here rather than at the gateway.
  """
  def changeset(message, attrs) do
    message
    |> cast(attrs, [:room, :body])
    |> update_change(:room, &String.trim/1)
    |> update_change(:body, &String.trim/1)
    |> validate_required([:room, :user_id, :nickname, :body])
    |> validate_length(:room, min: 1, max: 64)
    |> validate_length(:nickname, min: 1, max: 64)
    |> validate_length(:body, min: 1, max: 2000)
  end
end
