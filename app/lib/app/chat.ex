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

  Reading does not match a scope the same way, and that difference is
  deliberate. A task is owned data; a room is a shared space whose slug is
  the capability, so its history is returned whole to anyone the room admits.
  Filtering reads by sender would also break the two-surface check this demo
  exists for, where a message typed on `/chat` has to show up on `/probe`.

  ## Ownership and sharing

  Who a room admits is a SQL predicate in the gateway, not a pattern match
  here: a room with no row is an implicit link room open to anyone holding
  the slug (exactly what every room was before rooms became rows), while a
  claimed room's row decides who may read and write. The room management
  functions — create, rename, share, revoke, delete — are owner-bound and
  match a scope with a user.

  Persistence is best-effort on purpose, but only against an *unreachable*
  gateway — running `mix phx.server` without `wrangler dev`, say — where
  `create_message/3` still returns a message struct so the transport can be
  exercised without a database. A gateway that answered and said no
  (`{:error, :forbidden}`) is an error and nothing is broadcast: treating
  denial as "ephemeral" would let a revoked member keep talking to the
  room. Callers can tell the modes apart via `d1_available?/0`.
  """

  alias App.Accounts.Scope
  alias App.Accounts.User
  alias App.Chat.Message
  alias App.Chat.Room
  alias App.D1
  alias Ecto.Changeset

  @default_room "lobby"
  @history_limit 50
  @room_format ~r/^[a-z0-9][a-z0-9-]{0,63}$/
  # Claiming a random slug that is already taken is a one-in-2^40 event, so
  # one retry is plenty and a second conflict is worth surfacing.
  @create_room_attempts 3

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

  ## Rooms

  @doc """
  Resolves `slug` as seen by the scope's user (or an anonymous caller).

  Returns `{:ok, %{room: room, role: role}}` when the caller may enter:
  `room` is `nil` for a slug that was never claimed — an implicit link room
  — and `role` is `:owner`, `:member` or `:link`. Returns
  `{:error, :forbidden}` when the room exists and denies the caller.

  An unreachable gateway resolves to the implicit link room: with no
  database there are no room rows to consult, and chat is already running
  in ephemeral mode (see `create_message/4`).
  """
  @spec room_access(Scope.t() | nil, String.t()) ::
          {:ok, %{room: Room.t() | nil, role: :owner | :member | :link}}
          | {:error, :forbidden | term()}
  def room_access(scope, slug) when is_binary(slug) do
    case D1.get_room(slug, user_id(scope)) do
      {:ok, {row, role}} -> {:ok, %{room: to_room(row, role), role: parse_role(role)}}
      {:error, :not_found} -> {:ok, %{room: nil, role: :link}}
      {:error, :gateway_unreachable} -> {:ok, %{room: nil, role: :link}}
      {:error, _reason} = error -> error
    end
  end

  @doc "Returns the rooms the scope's user owns or is a member of, newest first."
  @spec list_rooms(Scope.t()) :: {:ok, [Room.t()]} | {:error, term()}
  def list_rooms(%Scope{user: %{id: user_id}}) do
    with {:ok, rows} <- D1.list_rooms(user_id) do
      {:ok, Enum.map(rows, &to_room(&1, &1["role"]))}
    end
  end

  @doc """
  Claims a fresh slug for the scope's user and returns the room.

  `attrs` may carry `:name` and `:visibility` (default `"private"` — a room
  someone bothers to create is theirs until they open it up). The slug is
  generated, never supplied; a conflict with an existing claim is answered
  by generating another.
  """
  @spec create_room(Scope.t(), map()) :: {:ok, Room.t()} | {:error, Changeset.t() | term()}
  def create_room(%Scope{user: %{id: user_id}}, attrs \\ %{}) do
    %Room{}
    |> Room.changeset(attrs)
    |> Changeset.apply_action(:insert)
    |> case do
      {:ok, room} -> insert_room(user_id, room, @create_room_attempts)
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp insert_room(_user_id, _room, 0), do: {:error, :conflict}

  defp insert_room(user_id, room, attempts) do
    params = %{user_id: user_id, slug: new_room(), name: room.name, visibility: room.visibility}

    case D1.create_room(params) do
      {:ok, row} -> {:ok, to_room(row, "owner")}
      {:error, :conflict} -> insert_room(user_id, room, attempts - 1)
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Updates the scope's own room (`:name`, `:visibility`).

  A room the user does not own is `{:error, :not_found}`, exactly as with
  tasks.
  """
  @spec update_room(Scope.t(), String.t(), map()) ::
          {:ok, Room.t()} | {:error, Changeset.t() | term()}
  def update_room(%Scope{user: %{id: user_id}}, slug, attrs) when is_binary(slug) do
    %Room{}
    |> Room.changeset(attrs)
    |> Changeset.apply_action(:update)
    |> case do
      {:ok, room} ->
        with {:ok, row} <-
               D1.update_room(slug, user_id, %{name: room.name, visibility: room.visibility}) do
          {:ok, to_room(row, "owner")}
        end

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Deletes the scope's own room — and, in the same gateway batch, its
  messages, so a private transcript is never re-published as an unclaimed
  link room. Broadcasts `{:room_deleted}` so connected clients leave.
  """
  @spec delete_room(Scope.t(), String.t()) :: :ok | {:error, term()}
  def delete_room(%Scope{user: %{id: user_id}}, slug) when is_binary(slug) do
    with :ok <- D1.delete_room(slug, user_id) do
      Phoenix.PubSub.broadcast(App.PubSub, topic(slug), {:room_deleted})
      :ok
    end
  end

  @doc """
  Shares the scope's own room with the account registered under `email`.

  Sharing is with existing accounts only — there is no invitation email
  (delivery may not even be configured; see
  `App.Accounts.email_delivery_available?/0`), and link visibility is the
  escape hatch for everyone else. Returns the member's user row data.

  `{:error, :unknown_email}` when no account matches; `{:error, :conflict}`
  when the room is already shared with them; `{:error, :not_found}` when
  the room is not the scope's to share (or the email is the owner's own).
  """
  @spec share_room(Scope.t(), String.t(), String.t()) ::
          {:ok, %{id: integer(), email: String.t()}} | {:error, term()}
  def share_room(%Scope{user: %{id: user_id}} = _scope, slug, email)
      when is_binary(slug) and is_binary(email) do
    case App.Accounts.get_user_by_email(email) do
      nil ->
        {:error, :unknown_email}

      member ->
        with {:ok, _row} <- D1.create_room_membership(slug, user_id, member.id) do
          {:ok, %{id: member.id, email: member.email}}
        end
    end
  end

  @doc """
  Revokes `member_id`'s membership of the scope's own room.

  Broadcasts `{:access_revoked, member_id}` on the room topic so the
  member's live sessions are disconnected — authorization is otherwise only
  checked on join. Revoking someone who was not a member is `{:ok, 0}`.
  """
  @spec unshare_room(Scope.t(), String.t(), integer()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def unshare_room(%Scope{user: %{id: user_id}}, slug, member_id)
      when is_binary(slug) and is_integer(member_id) do
    with {:ok, count} <- D1.delete_room_membership(slug, member_id, user_id) do
      if count > 0 do
        Phoenix.PubSub.broadcast(App.PubSub, topic(slug), {:access_revoked, member_id})
      end

      {:ok, count}
    end
  end

  @doc "Removes the scope's user from a room they are a member of."
  @spec leave_room(Scope.t(), String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def leave_room(%Scope{user: %{id: user_id}}, slug) when is_binary(slug) do
    D1.delete_room_membership(slug, user_id, user_id)
  end

  @doc "Returns who the scope's own room is shared with."
  @spec list_members(Scope.t(), String.t()) ::
          {:ok, [%{id: integer(), user_id: integer(), email: String.t()}]} | {:error, term()}
  def list_members(%Scope{user: %{id: user_id}}, slug) when is_binary(slug) do
    with {:ok, rows} <- D1.list_room_memberships(slug, user_id) do
      {:ok,
       Enum.map(rows, fn row ->
         %{id: row["id"], user_id: row["user_id"], email: row["email"]}
       end)}
    end
  end

  ## Messages

  @doc """
  Returns the recent history for `room` as seen by the scope, oldest first.

  Returns `{:error, :forbidden}` when the room denies the caller, and
  `{:error, reason}` when D1 is unreachable so the caller can show an
  ephemeral-mode banner rather than an empty transcript.
  """
  @spec recent_messages(Scope.t() | nil, String.t(), pos_integer()) ::
          {:ok, [Message.t()]} | {:error, term()}
  def recent_messages(scope, room, limit \\ @history_limit) do
    with {:ok, rows} <- D1.list_messages(room, limit, user_id(scope)) do
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
  `{:ok, message, :persisted | :ephemeral}`, `{:error, changeset}` when
  validation fails, or `{:error, :forbidden}` when the room denies the
  sender — in which case nothing is broadcast.

  `user_id` and `nickname` are set from the scope, never cast from the
  caller's attributes: a client that could name itself could impersonate
  another account in the transcript.

  `:ephemeral` happens only when the gateway is *unreachable* (local dev
  without `wrangler dev`): the message gets a client-side id so streams and
  DOM ids still work, and the transport can be tested without a database. A
  gateway that answered and refused is never downgraded to `:ephemeral` —
  that would let a denied sender keep talking to the room.
  """
  @spec create_message(Scope.t(), String.t(), String.t()) ::
          {:ok, Message.t(), :persisted | :ephemeral}
          | {:error, Changeset.t() | :forbidden | term()}
  def create_message(%Scope{user: %User{id: user_id}} = scope, room, body) do
    %Message{user_id: user_id, nickname: sender_name(scope)}
    |> Message.changeset(%{room: room, body: body})
    |> Changeset.apply_action(:insert)
    |> case do
      {:ok, message} ->
        with {:ok, stored, durability} <- persist(message) do
          Phoenix.PubSub.broadcast(App.PubSub, topic(room), {:new_message, stored})
          {:ok, stored, durability}
        end

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
        {:ok, to_message(row), :persisted}

      {:error, :gateway_unreachable} ->
        # Keep the socket usable without a database: give the message a
        # client-side id so streams and DOM ids still work.
        {:ok, %{message | id: System.unique_integer([:positive]), inserted_at: utc_now()},
         :ephemeral}

      {:error, _reason} = error ->
        error
    end
  end

  defp utc_now, do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

  ## Scope

  # Reads pass the viewer to the gateway rather than matching on one, so a
  # scope with no user reads as "no user" instead of raising. Writes and room
  # management do match, which is where a missing account is a bug.
  defp user_id(%Scope{user: %{id: id}}), do: id
  defp user_id(_scope), do: nil

  ## Row conversion

  defp to_room(row, role) do
    %Room{
      id: row["id"],
      slug: row["slug"],
      user_id: row["user_id"],
      name: row["name"],
      visibility: row["visibility"],
      role: parse_role(role),
      inserted_at: parse_timestamp(row["inserted_at"]),
      updated_at: parse_timestamp(row["updated_at"])
    }
  end

  defp parse_role("owner"), do: :owner
  defp parse_role("member"), do: :member
  defp parse_role(_role), do: :link

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
