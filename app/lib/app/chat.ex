defmodule App.Chat do
  @moduledoc """
  Chat room context for the WebSocket/Channel smoke test.

  Messages are broadcast over `Phoenix.PubSub` (the Worker routes every
  request to a single Durable Object, so all sockets live on one BEAM node
  and the local PubSub adapter is enough) and persisted to Cloudflare D1
  through the private gateway in `App.D1`.

  Sending takes an `App.Accounts.Scope` as its first argument and *matches*
  it, the way `App.Tasks` does: `/chat` and `/probe` both require a logged-in
  account, so the sender is the session's user and a scope without one raises
  here rather than writing an unattributed message.

  Reading does not take a scope, and that difference is deliberate. A task is
  owned data; a room is a shared space whose slug is the capability, so its
  history is returned whole to anyone holding the link. Filtering reads by
  sender would also break the two-surface check this demo exists for, where a
  message typed on `/chat` has to show up on `/probe`.

  Persistence is best-effort on purpose: when the gateway is unreachable —
  running `mix phx.server` without `wrangler dev`, say — `create_message/3`
  still returns a message struct so the transport can be exercised without a
  database. Callers can tell the two apart via `d1_available?/0`.
  """

  alias App.Accounts.Scope
  alias App.Accounts.User
  alias App.Chat.Message
  alias App.D1
  alias Ecto.Changeset

  @default_room "lobby"
  @history_limit 50
  @room_format ~r/^[a-z0-9][a-z0-9-]{0,63}$/

  @doc "The room joined when no room is named."
  @spec default_room() :: String.t()
  def default_room, do: @default_room

  @doc """
  Generates a room slug for a new shareable session.

  Base32 without padding keeps it short, lowercase and safe in a URL, a
  channel topic and a SQL bind alike.
  """
  @spec new_room() :: String.t()
  def new_room do
    :crypto.strong_rand_bytes(5) |> Base.encode32(case: :lower, padding: false)
  end

  @doc """
  True when `room` is a safe slug.

  Room names arrive from the client — in a URL and in a channel topic — so
  everything that reaches a topic or the database is validated here.
  """
  @spec valid_room?(term()) :: boolean()
  def valid_room?(room) when is_binary(room), do: Regex.match?(@room_format, room)
  def valid_room?(_room), do: false

  @doc "Returns `room` when it is a valid slug, otherwise the default room."
  @spec room_or_default(term()) :: String.t()
  def room_or_default(room), do: if(valid_room?(room), do: room, else: @default_room)

  @doc """
  The PubSub topic carrying `room`'s messages.

  Deliberately *not* the `"room:<name>"` channel topic: a channel process is
  already subscribed to its own topic, so broadcasting there would deliver
  every message to `AppWeb.RoomChannel` twice.
  """
  @spec topic(String.t()) :: String.t()
  def topic(room), do: "chat:" <> room

  @doc "Subscribes the calling process to `room`."
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(room), do: Phoenix.PubSub.subscribe(App.PubSub, topic(room))

  @doc """
  Returns the recent history for `room`, oldest first.

  Returns `{:error, reason}` when D1 is unreachable so the caller can show
  an ephemeral-mode banner rather than an empty transcript.
  """
  @spec recent_messages(String.t(), pos_integer()) :: {:ok, [Message.t()]} | {:error, term()}
  def recent_messages(room, limit \\ @history_limit) do
    with {:ok, rows} <- D1.list_messages(room, limit) do
      {:ok, Enum.map(rows, &to_message/1)}
    end
  end

  @doc "True when the D1 gateway answered the last history read."
  @spec d1_available?() :: boolean()
  def d1_available? do
    match?({:ok, _rows}, D1.list_messages(@default_room, 1))
  end

  @doc """
  The name a message is labelled with when sent by `scope`'s user.

  Stored on the row alongside `user_id`, so renaming an account never
  rewrites history.
  """
  @spec sender_name(Scope.t()) :: String.t()
  def sender_name(%Scope{user: %User{} = user}), do: User.display_name(user)

  @doc """
  Validates, persists and broadcasts a message sent by `scope`'s user.

  Broadcasts `{:new_message, message}` on the room topic. Returns
  `{:ok, message, :persisted | :ephemeral}`, or `{:error, changeset}` when
  validation fails — a failed write is never an error for the caller, since
  the point of this demo is the transport.

  `user_id` and `nickname` are set from the scope, never cast from the
  caller's attributes: a client that could name itself could impersonate
  another account in the transcript.
  """
  @spec create_message(Scope.t(), String.t(), String.t()) ::
          {:ok, Message.t(), :persisted | :ephemeral} | {:error, Changeset.t()}
  def create_message(%Scope{user: %User{id: user_id}} = scope, room, body) do
    %Message{user_id: user_id, nickname: sender_name(scope)}
    |> Message.changeset(%{room: room, body: body})
    |> Changeset.apply_action(:insert)
    |> case do
      {:ok, message} ->
        {stored, durability} = persist(message)
        Phoenix.PubSub.broadcast(App.PubSub, topic(room), {:new_message, stored})
        {:ok, stored, durability}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  ## Persistence

  defp persist(%Message{} = message) do
    case D1.create_message(
           message.user_id,
           message.room,
           message.nickname,
           message.body
         ) do
      {:ok, row} ->
        {to_message(row), :persisted}

      {:error, _reason} ->
        # Keep the socket usable without a database: give the message a
        # client-side id so streams and DOM ids still work.
        {%{message | id: System.unique_integer([:positive]), inserted_at: utc_now()}, :ephemeral}
    end
  end

  defp utc_now, do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

  ## Row conversion

  defp to_message(row) do
    %Message{
      id: row["id"],
      room: row["room"],
      user_id: row["user_id"],
      nickname: row["nickname"],
      body: row["body"],
      inserted_at: parse_timestamp(row["inserted_at"])
    }
  end

  defp parse_timestamp(nil), do: nil

  defp parse_timestamp(timestamp) when is_binary(timestamp) do
    case NaiveDateTime.from_iso8601(timestamp) do
      {:ok, parsed} -> parsed
      {:error, _reason} -> nil
    end
  end
end
