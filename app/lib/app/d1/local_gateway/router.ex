if Mix.env() != :prod do
  defmodule App.D1.LocalGateway.Router do
    @moduledoc """
    HTTP contract of the Worker's `D1Gateway`, served locally.

    Routes, status codes, response shapes and parameterized binds mirror
    `D1Gateway` in `src/index.ts`. When you add a route there, add it here
    too — a drift between the two makes local runs lie about production.
    """

    use Plug.Router

    alias App.D1.LocalGateway

    @task_columns "id, user_id, title, completed, inserted_at, updated_at"
    @message_columns "id, room, user_id, nickname, body, inserted_at"
    @message_limit_default 50
    @message_limit_max 200
    @user_columns "id, email, hashed_password, confirmed_at, inserted_at, updated_at"
    @user_token_columns "id, user_id, token, context, sent_to, authenticated_at, inserted_at"
    @token_format ~r/^[0-9a-f]{64}$/
    @timestamp_format ~r/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/
    @email_max_length 160
    @context_max_length 100
    @hashed_password_max_length 255

    plug :match
    plug Plug.Parsers, parsers: [:json], pass: ["application/json"], json_decoder: Jason
    plug :dispatch

    ## Messages

    get "/messages" do
      room = conn.params["room"] |> to_text(64)

      if is_nil(room) do
        send_json(conn, 400, %{error: "room is required"})
      else
        {:ok, rows} =
          LocalGateway.query(
            "SELECT #{@message_columns} FROM messages WHERE room = ?1 ORDER BY id DESC LIMIT ?2",
            [room, message_limit(conn.params["limit"])]
          )

        send_json(conn, 200, %{messages: Enum.reverse(rows)})
      end
    end

    post "/messages" do
      room = to_text(conn.params["room"], 64)
      nickname = to_text(conn.params["nickname"], 64)
      body = to_text(conn.params["body"], 2000)
      user_id = parse_id(conn.params["user_id"])

      cond do
        is_nil(room) or is_nil(nickname) or is_nil(body) ->
          send_json(conn, 400, %{
            error: "room, nickname and body must be non-empty strings within their length limits"
          })

        is_nil(user_id) ->
          send_json(conn, 400, %{error: "user_id is required"})

        true ->
          {:ok, [row]} =
            LocalGateway.query(
              "INSERT INTO messages (room, user_id, nickname, body) VALUES (?1, ?2, ?3, ?4) " <>
                "RETURNING #{@message_columns}",
              [room, user_id, nickname, body]
            )

          send_json(conn, 201, %{message: row})
      end
    end

    ## Accounts (users and their tokens)

    get "/users" do
      case to_text(conn.params["email"], @email_max_length) do
        nil ->
          send_json(conn, 400, %{error: "email is required"})

        email ->
          # Stands in for Postgres citext; see the unique index on lower(email).
          "SELECT #{@user_columns} FROM users WHERE lower(email) = lower(?1)"
          |> query([email])
          |> one(conn, &send_json(conn, 200, %{user: &1}))
      end
    end

    post "/users" do
      with {:ok, email} <- require_text(conn.params["email"], @email_max_length),
           {:ok, hashed_password} <-
             optional_text(conn.params["hashed_password"], @hashed_password_max_length),
           {:ok, confirmed_at} <- optional_timestamp(conn.params["confirmed_at"]) do
        ("INSERT INTO users (email, hashed_password, confirmed_at) VALUES (?1, ?2, ?3) " <>
           "RETURNING #{@user_columns}")
        |> query([email, hashed_password, confirmed_at])
        |> case do
          {:ok, [row]} -> send_json(conn, 201, %{user: row})
          {:error, reason} -> send_db_error(conn, reason)
        end
      else
        :error -> send_json(conn, 400, %{error: "invalid user attributes"})
      end
    end

    get "/users/:id" do
      case parse_id(id) do
        nil ->
          send_json(conn, 400, %{error: "invalid user id"})

        user_id ->
          "SELECT #{@user_columns} FROM users WHERE id = ?1"
          |> query([user_id])
          |> one(conn, &send_json(conn, 200, %{user: &1}))
      end
    end

    # Updates a user and, optionally, expires their tokens in the same
    # transaction — the local equivalent of the gateway's `db.batch/1`, and
    # what keeps `App.Accounts.update_user_password/2` atomic.
    patch "/users/:id" do
      with user_id when not is_nil(user_id) <- parse_id(id),
           {:ok, [_ | _] = updates} <- user_updates(conn.params),
           {:ok, delete_context} <-
             optional_text(conn.params["delete_tokens_context"], @context_max_length) do
        {columns, values} = Enum.unzip(updates)

        # Column names come from the allowlist in user_updates/1, never from
        # the request; only values are bound.
        assignments =
          columns
          |> Enum.with_index(1)
          |> Enum.map_join(", ", fn {column, index} -> "#{column} = ?#{index}" end)

        statements =
          [
            {"UPDATE users SET #{assignments}, updated_at = CURRENT_TIMESTAMP " <>
               "WHERE id = ?#{length(columns) + 1} RETURNING #{@user_columns}",
             values ++ [user_id]}
          ] ++ token_deletion(conn.params["delete_all_tokens"], delete_context, user_id)

        case LocalGateway.transaction(statements) do
          {:ok, [[user] | rest]} ->
            send_json(conn, 200, %{user: user, expired_tokens: List.flatten(rest)})

          {:ok, [[] | _rest]} ->
            send_json(conn, 404, %{error: "not found"})

          {:error, reason} ->
            send_db_error(conn, reason)
        end
      else
        nil -> send_json(conn, 400, %{error: "invalid user id"})
        {:ok, []} -> send_json(conn, 400, %{error: "no user attributes to update"})
        :error -> send_json(conn, 400, %{error: "invalid user attributes"})
      end
    end

    post "/user_tokens" do
      with user_id when not is_nil(user_id) <- parse_id(conn.params["user_id"]),
           {:ok, token} <- require_token(conn.params["token"]),
           {:ok, context} <- require_text(conn.params["context"], @context_max_length),
           {:ok, sent_to} <- optional_text(conn.params["sent_to"], @email_max_length),
           {:ok, authenticated_at} <- optional_timestamp(conn.params["authenticated_at"]) do
        ("INSERT INTO users_tokens (user_id, token, context, sent_to, authenticated_at) " <>
           "VALUES (?1, ?2, ?3, ?4, ?5) RETURNING #{@user_token_columns}")
        |> query([user_id, token, context, sent_to, authenticated_at])
        |> case do
          {:ok, [row]} -> send_json(conn, 201, %{user_token: row})
          {:error, reason} -> send_db_error(conn, reason)
        end
      else
        _other -> send_json(conn, 400, %{error: "invalid token attributes"})
      end
    end

    get "/user_tokens" do
      with {:ok, token} <- require_token(conn.params["token"]),
           {:ok, context} <- require_text(conn.params["context"], @context_max_length) do
        {:ok, rows} =
          query(
            "SELECT #{@user_token_columns} FROM users_tokens WHERE context = ?1 AND token = ?2",
            [context, token]
          )

        case rows do
          [user_token] ->
            {:ok, users} =
              query("SELECT #{@user_columns} FROM users WHERE id = ?1", [user_token["user_id"]])

            case users do
              [user] -> send_json(conn, 200, %{user_token: user_token, user: user})
              [] -> send_json(conn, 404, %{error: "not found"})
            end

          [] ->
            send_json(conn, 404, %{error: "not found"})
        end
      else
        :error -> send_json(conn, 400, %{error: "token and context are required"})
      end
    end

    delete "/user_tokens" do
      with {:ok, token} <- require_token(conn.params["token"]),
           {:ok, context} <- require_text(conn.params["context"], @context_max_length) do
        {:ok, rows} =
          query(
            "DELETE FROM users_tokens WHERE context = ?1 AND token = ?2 RETURNING id",
            [context, token]
          )

        send_json(conn, 200, %{deleted: length(rows)})
      else
        :error -> send_json(conn, 400, %{error: "token and context are required"})
      end
    end

    ## Tasks

    get "/tasks" do
      case parse_id(conn.params["user_id"]) do
        nil ->
          send_json(conn, 400, %{error: "user_id is required"})

        user_id ->
          {:ok, rows} =
            LocalGateway.query(
              "SELECT #{@task_columns} FROM tasks WHERE user_id = ?1 " <>
                "ORDER BY inserted_at DESC, id DESC",
              [user_id]
            )

          send_json(conn, 200, %{tasks: rows})
      end
    end

    post "/tasks" do
      title = to_text(conn.params["title"], 255)
      user_id = parse_id(conn.params["user_id"])

      cond do
        is_nil(title) ->
          send_json(conn, 400, %{
            error: "title must be a non-empty string of at most 255 characters"
          })

        is_nil(user_id) ->
          send_json(conn, 400, %{error: "user_id is required"})

        true ->
          {:ok, [row]} =
            LocalGateway.query(
              "INSERT INTO tasks (user_id, title, completed) VALUES (?1, ?2, 0) " <>
                "RETURNING #{@task_columns}",
              [user_id, title]
            )

          send_json(conn, 201, %{task: row})
      end
    end

    get "/tasks/:id" do
      with_task(conn, id, fn row -> send_json(conn, 200, %{task: row}) end)
    end

    patch "/tasks/:id" do
      with_task(conn, id, fn current ->
        title =
          case conn.params["title"] do
            nil -> current["title"]
            value -> to_text(value, 255)
          end

        completed =
          case conn.params["completed"] do
            nil -> current["completed"] == 1
            value -> !!value
          end

        if is_nil(title) do
          send_json(conn, 400, %{
            error: "title must be a non-empty string of at most 255 characters"
          })
        else
          {:ok, [row]} =
            LocalGateway.query(
              "UPDATE tasks SET title = ?1, completed = ?2, updated_at = CURRENT_TIMESTAMP " <>
                "WHERE id = ?3 AND user_id = ?4 RETURNING #{@task_columns}",
              [title, if(completed, do: 1, else: 0), current["id"], current["user_id"]]
            )

          send_json(conn, 200, %{task: row})
        end
      end)
    end

    delete "/tasks/:id" do
      with_task_id(conn, id, fn task_id, user_id ->
        case LocalGateway.query(
               "DELETE FROM tasks WHERE id = ?1 AND user_id = ?2 RETURNING id",
               [task_id, user_id]
             ) do
          {:ok, [_row]} -> send_json(conn, 200, %{deleted: true})
          {:ok, []} -> send_json(conn, 404, %{error: "not found"})
        end
      end)
    end

    match _ do
      send_json(conn, 404, %{error: "not found"})
    end

    ## Helpers

    defp query(sql, params), do: LocalGateway.query(sql, params)

    defp one({:ok, [row]}, _conn, fun), do: fun.(row)
    defp one({:ok, []}, conn, _fun), do: send_json(conn, 404, %{error: "not found"})

    # The allowlist of columns `PATCH /users/:id` may set, in the order the
    # request supplied them. Absent keys are left alone; present-but-invalid
    # values abort the whole update.
    defp user_updates(params) do
      [
        {"email", &require_text(&1, @email_max_length)},
        {"hashed_password", &require_text(&1, @hashed_password_max_length)},
        {"confirmed_at", &require_timestamp/1}
      ]
      |> Enum.reduce_while({:ok, []}, fn {column, parse}, {:ok, acc} ->
        case Map.fetch(params, column) do
          :error -> {:cont, {:ok, acc}}
          {:ok, value} -> continue_update(parse.(value), column, acc)
        end
      end)
    end

    defp continue_update({:ok, parsed}, column, acc),
      do: {:cont, {:ok, acc ++ [{column, parsed}]}}

    defp continue_update(:error, _column, _acc), do: {:halt, :error}

    defp token_deletion(true, _context, user_id) do
      [
        {"DELETE FROM users_tokens WHERE user_id = ?1 RETURNING #{@user_token_columns}",
         [user_id]}
      ]
    end

    defp token_deletion(_delete_all, context, user_id) when is_binary(context) do
      [
        {"DELETE FROM users_tokens WHERE user_id = ?1 AND context = ?2 " <>
           "RETURNING #{@user_token_columns}", [user_id, context]}
      ]
    end

    defp token_deletion(_delete_all, _context, _user_id), do: []

    defp require_text(value, max_length) do
      case to_text(value, max_length) do
        nil -> :error
        text -> {:ok, text}
      end
    end

    # `nil` means "not supplied" — the column keeps its default or current
    # value — while an unusable value is an error, as in the Worker's gateway.
    defp optional_text(nil, _max_length), do: {:ok, nil}
    defp optional_text(value, max_length), do: require_text(value, max_length)

    defp require_timestamp(value) when is_binary(value) do
      if Regex.match?(@timestamp_format, value), do: {:ok, value}, else: :error
    end

    defp require_timestamp(_value), do: :error

    defp optional_timestamp(nil), do: {:ok, nil}
    defp optional_timestamp(value), do: require_timestamp(value)

    defp require_token(value) when is_binary(value) do
      if Regex.match?(@token_format, value), do: {:ok, value}, else: :error
    end

    defp require_token(_value), do: :error

    defp send_db_error(conn, reason) do
      if LocalGateway.unique_violation?(reason) do
        send_json(conn, 409, %{error: "email has already been taken"})
      else
        send_json(conn, 500, %{error: "database error"})
      end
    end

    defp with_task(conn, id, fun) do
      with_task_id(conn, id, fn task_id, user_id ->
        case LocalGateway.query(
               "SELECT #{@task_columns} FROM tasks WHERE id = ?1 AND user_id = ?2",
               [task_id, user_id]
             ) do
          {:ok, [row]} -> fun.(row)
          {:ok, []} -> send_json(conn, 404, %{error: "not found"})
        end
      end)
    end

    # Tasks are owned, so the owner is part of addressing one: `user_id` is
    # required on every single-task route and bound alongside the id in every
    # statement, which turns another user's task into a 404 rather than a leak.
    defp with_task_id(conn, id, fun) do
      case {parse_id(id), parse_id(conn.params["user_id"])} do
        {nil, _user_id} -> send_json(conn, 400, %{error: "invalid task id"})
        {_task_id, nil} -> send_json(conn, 400, %{error: "user_id is required"})
        {task_id, user_id} -> fun.(task_id, user_id)
      end
    end

    defp parse_id(id) do
      case Integer.parse(to_string(id)) do
        {parsed, ""} when parsed >= 1 -> parsed
        _other -> nil
      end
    end

    defp message_limit(nil), do: @message_limit_default

    defp message_limit(value) do
      case Integer.parse(to_string(value)) do
        {parsed, ""} when parsed >= 1 -> min(parsed, @message_limit_max)
        _other -> @message_limit_default
      end
    end

    defp to_text(value, max_length) when is_binary(value) do
      trimmed = String.trim(value)
      if trimmed != "" and String.length(trimmed) <= max_length, do: trimmed
    end

    defp to_text(_value, _max_length), do: nil

    defp send_json(conn, status, body) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(body))
    end
  end
end
