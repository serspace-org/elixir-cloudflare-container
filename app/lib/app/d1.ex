defmodule App.D1 do
  @moduledoc """
  HTTP client for the private D1 gateway exposed by the Cloudflare Worker.

  The Worker registers a `d1.internal` outbound HTTP intercept for the
  container (see `D1Gateway` in `src/index.ts`), backed by the Worker's
  `DB` D1 binding. The hostname resolves only inside the container, so the
  database is never exposed to the public internet and no credentials ship
  in the image.

  Functions return raw row maps; the contexts (`App.Tasks`, `App.Chat`,
  `App.Accounts`) convert them into structs.

  Arguments, by contrast, are ordinary Elixir values: the two encodings the
  gateway's wire format needs — raw token bytes as lowercase hex, and
  `DateTime`s in SQLite's `CURRENT_TIMESTAMP` format — are applied here so
  callers never have to think about them.
  """

  require Logger

  @base_url Application.compile_env(:app, :d1_url, "http://d1.internal")

  # Every stored token is 32 bytes: session tokens are that many random bytes,
  # emailed ones are a SHA-256 digest. Anything else — a mangled cookie, a
  # hand-typed URL — cannot match a row, so it is answered without a round
  # trip rather than as a 400 from the gateway.
  defguardp is_token(value) when is_binary(value) and byte_size(value) == 32

  ## Messages (chat demo)

  @doc """
  Returns up to `limit` messages for `room`, oldest first.
  """
  @spec list_messages(String.t(), pos_integer()) :: {:ok, [map()]} | {:error, term()}
  def list_messages(room, limit \\ 50) when is_binary(room) and is_integer(limit) do
    query = URI.encode_query(%{"room" => room, "limit" => limit})

    case request(:get, "/messages?" <> query) do
      {:ok, %{"messages" => rows}} -> {:ok, rows}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Persists a chat message sent by `user_id` and returns its row.

  Unlike `list_messages/2`, which is room-scoped on purpose — a room is a
  shared space, so its history is not filtered by sender — a write always
  carries its author: `/chat` and `/probe` require a logged-in account.
  """
  @spec create_message(integer(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def create_message(user_id, room, nickname, body)
      when is_integer(user_id) and is_binary(room) and is_binary(nickname) and is_binary(body) do
    case request(:post, "/messages", %{
           room: room,
           user_id: user_id,
           nickname: nickname,
           body: body
         }) do
      {:ok, %{"message" => row}} -> {:ok, row}
      {:error, _reason} = error -> error
    end
  end

  ## Tasks

  # Tasks are owned, and ownership is enforced in SQL rather than here: the
  # gateway binds `user_id` alongside the id in every task statement, so a
  # task belonging to someone else answers 404 — which `App.Tasks` sees as
  # `{:error, :not_found}`, the same as a task that never existed.

  @doc "Returns `user_id`'s task rows, newest first."
  @spec list_tasks(integer()) :: {:ok, [map()]} | {:error, term()}
  def list_tasks(user_id) when is_integer(user_id) do
    query = URI.encode_query(%{"user_id" => user_id})

    case request(:get, "/tasks?" <> query) do
      {:ok, %{"tasks" => rows}} -> {:ok, rows}
      {:error, _reason} = error -> error
    end
  end

  @doc "Creates a task owned by `user_id` and returns its row."
  @spec create_task(integer(), String.t()) :: {:ok, map()} | {:error, term()}
  def create_task(user_id, title) when is_integer(user_id) and is_binary(title) do
    case request(:post, "/tasks", %{user_id: user_id, title: title}) do
      {:ok, %{"task" => row}} -> {:ok, row}
      {:error, _reason} = error -> error
    end
  end

  @doc "Returns `user_id`'s task row for `id`, or `{:error, :not_found}`."
  @spec get_task(integer(), integer() | String.t()) :: {:ok, map()} | {:error, term()}
  def get_task(user_id, id) when is_integer(user_id) do
    case request(:get, "/tasks/#{id}?" <> task_scope(user_id)) do
      {:ok, %{"task" => row}} -> {:ok, row}
      {:error, _reason} = error -> error
    end
  end

  @doc "Updates `user_id`'s task and returns its row."
  @spec update_task(integer(), integer() | String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def update_task(user_id, id, attrs) when is_integer(user_id) and is_map(attrs) do
    case request(:patch, "/tasks/#{id}?" <> task_scope(user_id), attrs) do
      {:ok, %{"task" => row}} -> {:ok, row}
      {:error, _reason} = error -> error
    end
  end

  @doc "Deletes `user_id`'s task with `id`."
  @spec delete_task(integer(), integer() | String.t()) :: :ok | {:error, term()}
  def delete_task(user_id, id) when is_integer(user_id) do
    case request(:delete, "/tasks/#{id}?" <> task_scope(user_id)) do
      {:ok, _body} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp task_scope(user_id), do: URI.encode_query(%{"user_id" => user_id})

  ## Accounts (see App.Accounts)

  @doc "Returns the user row for `email`, matched case-insensitively."
  @spec get_user_by_email(String.t()) :: {:ok, map()} | {:error, term()}
  def get_user_by_email(email) when is_binary(email) do
    query = URI.encode_query(%{"email" => email})

    case request(:get, "/users?" <> query) do
      {:ok, %{"user" => row}} -> {:ok, row}
      {:error, _reason} = error -> error
    end
  end

  @doc "Returns the user row for `id`."
  @spec get_user(integer()) :: {:ok, map()} | {:error, term()}
  def get_user(id) do
    case request(:get, "/users/#{id}") do
      {:ok, %{"user" => row}} -> {:ok, row}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Creates a user from `attrs` (`:email`, `:hashed_password`, `:confirmed_at`).

  Returns `{:error, :conflict}` when the unique index on `lower(email)`
  rejects the row, which `App.Accounts` turns into a changeset error.
  """
  @spec create_user(map()) :: {:ok, map()} | {:error, term()}
  def create_user(attrs) when is_map(attrs) do
    case request(:post, "/users", user_params(attrs)) do
      {:ok, %{"user" => row}} -> {:ok, row}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Updates a user and, in the same transaction, optionally expires their tokens.

  Beyond the user columns, `attrs` accepts `delete_all_tokens: true` or
  `delete_tokens_context: context`. Returns `{:ok, {user_row, expired_rows}}`;
  `expired_rows` is empty unless a deletion was requested.
  """
  @spec update_user(integer(), map()) :: {:ok, {map(), [map()]}} | {:error, term()}
  def update_user(id, attrs) when is_map(attrs) do
    params =
      attrs
      |> Map.take([:delete_all_tokens, :delete_tokens_context])
      |> Map.merge(user_params(attrs))

    case request(:patch, "/users/#{id}", params) do
      {:ok, %{"user" => row, "expired_tokens" => expired}} -> {:ok, {row, expired}}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Persists a token row.

  `attrs` takes `:user_id`, `:token` (raw bytes), `:context`, and optionally
  `:sent_to` and `:authenticated_at`.
  """
  @spec create_user_token(map()) :: {:ok, map()} | {:error, term()}
  def create_user_token(%{user_id: user_id, token: token, context: context} = attrs) do
    params = %{
      user_id: user_id,
      token: encode_token(token),
      context: context,
      sent_to: Map.get(attrs, :sent_to),
      authenticated_at: encode_timestamp(Map.get(attrs, :authenticated_at))
    }

    case request(:post, "/user_tokens", params) do
      {:ok, %{"user_token" => row}} -> {:ok, row}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Returns `{:ok, {token_row, user_row}}` for the token in `context`.

  Expiry is not checked here — the validity windows live in
  `App.Accounts.UserToken` and are applied by `App.Accounts`.
  """
  @spec get_user_token(binary(), String.t()) :: {:ok, {map(), map()}} | {:error, term()}
  def get_user_token(token, context) when is_token(token) and is_binary(context) do
    query = URI.encode_query(%{"token" => encode_token(token), "context" => context})

    case request(:get, "/user_tokens?" <> query) do
      {:ok, %{"user_token" => token_row, "user" => user_row}} -> {:ok, {token_row, user_row}}
      {:error, _reason} = error -> error
    end
  end

  def get_user_token(_token, _context), do: {:error, :not_found}

  @doc "Deletes the token in `context`, returning how many rows went away."
  @spec delete_user_token(binary(), String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def delete_user_token(token, context) when is_token(token) and is_binary(context) do
    query = URI.encode_query(%{"token" => encode_token(token), "context" => context})

    case request(:delete, "/user_tokens?" <> query) do
      {:ok, %{"deleted" => count}} -> {:ok, count}
      {:error, _reason} = error -> error
    end
  end

  def delete_user_token(_token, _context), do: {:ok, 0}

  @doc "Encodes raw token bytes the way the `users_tokens.token` column stores them."
  @spec encode_token(binary()) :: String.t()
  def encode_token(token) when is_binary(token), do: Base.encode16(token, case: :lower)

  @doc "Decodes a `users_tokens.token` value back into raw bytes."
  @spec decode_token(String.t()) :: binary()
  def decode_token(hex) when is_binary(hex), do: Base.decode16!(hex, case: :lower)

  defp user_params(attrs) do
    attrs
    |> Map.take([:email, :hashed_password, :confirmed_at])
    |> Map.new(fn
      {:confirmed_at, value} -> {:confirmed_at, encode_timestamp(value)}
      {key, value} -> {key, value}
    end)
  end

  # SQLite's CURRENT_TIMESTAMP format, which every timestamp column uses.
  defp encode_timestamp(nil), do: nil

  defp encode_timestamp(%DateTime{} = at) do
    at |> DateTime.truncate(:second) |> DateTime.to_naive() |> NaiveDateTime.to_string()
  end

  ## Transport

  defp request(method, path, body \\ nil) do
    options =
      [method: method, url: @base_url <> path, retry: false]
      |> put_json(body)
      |> Keyword.merge(Application.get_env(:app, :d1_req_options, []))

    case Req.request(options) do
      {:ok, %Req.Response{status: status, body: body}}
      when status in 200..299 and is_map(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: 404}} ->
        {:error, :not_found}

      # A unique index rejected the write. Which index depends on the route —
      # lower(users.email) on the user routes, for instance — so callers that
      # can say something more specific (App.Accounts and its changeset error
      # on :email) do the translating.
      {:ok, %Req.Response{status: 409}} ->
        {:error, :conflict}

      {:ok, %Req.Response{status: status}} ->
        Logger.error("D1 gateway returned HTTP #{status} for #{method} #{path}")
        {:error, {:gateway_status, status}}

      {:error, reason} ->
        Logger.error("D1 gateway unreachable for #{method} #{path}: #{inspect(reason)}")
        {:error, :gateway_unreachable}
    end
  end

  defp put_json(options, nil), do: options
  defp put_json(options, body), do: Keyword.put(options, :json, body)
end
