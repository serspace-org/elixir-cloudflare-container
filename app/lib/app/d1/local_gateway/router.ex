if Mix.env() != :prod do
  defmodule App.D1.LocalGateway.Router do
    @moduledoc """
    HTTP contract of the Worker's `D1Gateway`, served locally.

    Routes, status codes, response shapes and parameterized binds mirror
    `D1Gateway` in `src/index.ts`. When you add a route there, add it here
    too — a drift between the two makes local runs lie about production.

    Room authorization is enforced here, in SQL, exactly as in the Worker's
    gateway: a room with no row is an implicit *link* room open to anyone
    with the slug, and a row that denies the viewer answers 403, never an
    empty transcript.
    """

    use Plug.Router

    alias App.D1.LocalGateway

    @task_columns "id, user_id, title, completed, inserted_at, updated_at"
    @message_columns "id, room, user_id, nickname, body, inserted_at"
    @room_columns "id, slug, user_id, name, visibility, inserted_at, updated_at"
    @membership_columns "id, room_id, user_id, inserted_at"
    @room_name_max_length 160
    @room_visibilities ~w(link private)
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

      cond do
        is_nil(room) ->
          send_json(conn, 400, %{error: "room is required"})

        match?(:error, parse_viewer(conn.params["user_id"])) ->
          send_json(conn, 400, %{error: "invalid user_id"})

        true ->
          {:ok, viewer_id} = parse_viewer(conn.params["user_id"])

          case room_access(room, viewer_id) do
            %{allowed: false} ->
              send_json(conn, 403, %{error: "forbidden"})

            %{allowed: true} ->
              {:ok, rows} =
                LocalGateway.query(
                  "SELECT #{@message_columns} FROM messages WHERE room = ?1 " <>
                    "ORDER BY id DESC LIMIT ?2",
                  [room, message_limit(conn.params["limit"])]
                )

              send_json(conn, 200, %{messages: Enum.reverse(rows)})
          end
      end
    end

    post "/messages" do
      room = to_text(conn.params["room"], 64)
      nickname = to_text(conn.params["nickname"], 64)
      body = to_text(conn.params["body"], 2000)
      # Every chat surface requires a logged-in account, so a write always
      # carries its author; the room's row then decides whether that author
      # may write to it.
      user_id = parse_id(conn.params["user_id"])

      cond do
        is_nil(room) or is_nil(nickname) or is_nil(body) ->
          send_json(conn, 400, %{
            error: "room, nickname and body must be non-empty strings within their length limits"
          })

        is_nil(user_id) ->
          send_json(conn, 400, %{error: "user_id is required"})

        true ->
          case room_access(room, user_id) do
            %{allowed: false} ->
              send_json(conn, 403, %{error: "forbidden"})

            %{allowed: true} ->
              {:ok, [row]} =
                LocalGateway.query(
                  "INSERT INTO messages (room, user_id, nickname, body) " <>
                    "VALUES (?1, ?2, ?3, ?4) RETURNING #{@message_columns}",
                  [room, user_id, nickname, body]
                )

              send_json(conn, 201, %{message: row})
          end
      end
    end

    ## Rooms (owned, shareable chats; see App.Chat)

    get "/rooms" do
      case parse_id(conn.params["user_id"]) do
        nil ->
          send_json(conn, 400, %{error: "user_id is required"})

        user_id ->
          {:ok, rows} =
            LocalGateway.query(
              "SELECT #{@room_columns}, " <>
                "CASE WHEN user_id = ?1 THEN 'owner' ELSE 'member' END AS role " <>
                "FROM rooms WHERE user_id = ?1 OR EXISTS " <>
                "(SELECT 1 FROM room_memberships rm " <>
                "WHERE rm.room_id = rooms.id AND rm.user_id = ?1) " <>
                "ORDER BY inserted_at DESC, id DESC",
              [user_id]
            )

          send_json(conn, 200, %{rooms: rows})
      end
    end

    post "/rooms" do
      with user_id when not is_nil(user_id) <- parse_id(conn.params["user_id"]),
           {:ok, slug} <- require_text(conn.params["slug"], 64),
           {:ok, name} <- optional_text(conn.params["name"], @room_name_max_length),
           {:ok, visibility} <- require_visibility(conn.params["visibility"]) do
        ("INSERT INTO rooms (slug, user_id, name, visibility) VALUES (?1, ?2, ?3, ?4) " <>
           "RETURNING #{@room_columns}")
        |> query([slug, user_id, name, visibility])
        |> case do
          {:ok, [row]} -> send_json(conn, 201, %{room: row})
          {:error, reason} -> send_db_error(conn, reason)
        end
      else
        nil -> send_json(conn, 400, %{error: "user_id is required"})
        :error -> send_json(conn, 400, %{error: "invalid room attributes"})
      end
    end

    get "/rooms/:slug" do
      case parse_viewer(conn.params["user_id"]) do
        :error ->
          send_json(conn, 400, %{error: "invalid user_id"})

        {:ok, viewer_id} ->
          # 404 means "never claimed" — an implicit link room the caller may
          # enter; 403 means the row exists and denies this viewer.
          case room_access(slug, viewer_id) do
            %{room: nil} -> send_json(conn, 404, %{error: "not found"})
            %{allowed: false} -> send_json(conn, 403, %{error: "forbidden"})
            %{room: room, role: role} -> send_json(conn, 200, %{room: room, role: role})
          end
      end
    end

    patch "/rooms/:slug" do
      with user_id when not is_nil(user_id) <- parse_id(conn.params["user_id"]),
           {:ok, [_ | _] = updates} <- room_updates(conn.params) do
        {columns, values} = Enum.unzip(updates)

        # Column names come from the allowlist in room_updates/1, never from
        # the request. Owner-bound: anyone else updating a room is a 404, as
        # with tasks.
        assignments =
          columns
          |> Enum.with_index(1)
          |> Enum.map_join(", ", fn {column, index} -> "#{column} = ?#{index}" end)

        ("UPDATE rooms SET #{assignments}, updated_at = CURRENT_TIMESTAMP " <>
           "WHERE slug = ?#{length(columns) + 1} AND user_id = ?#{length(columns) + 2} " <>
           "RETURNING #{@room_columns}")
        |> query(values ++ [slug, user_id])
        |> one(conn, &send_json(conn, 200, %{room: &1}))
      else
        nil -> send_json(conn, 400, %{error: "user_id is required"})
        {:ok, []} -> send_json(conn, 400, %{error: "no room attributes to update"})
        :error -> send_json(conn, 400, %{error: "invalid room attributes"})
      end
    end

    # Deletes a room *and its messages* in one transaction — the local
    # equivalent of the gateway's `db.batch/1`. Without the message delete,
    # deleting a private room would revert it to an unclaimed link room and
    # quietly publish its history.
    delete "/rooms/:slug" do
      case parse_id(conn.params["user_id"]) do
        nil ->
          send_json(conn, 400, %{error: "user_id is required"})

        user_id ->
          case LocalGateway.transaction([
                 {"DELETE FROM messages WHERE room = ?1 AND EXISTS " <>
                    "(SELECT 1 FROM rooms WHERE slug = ?1 AND user_id = ?2)", [slug, user_id]},
                 {"DELETE FROM rooms WHERE slug = ?1 AND user_id = ?2 RETURNING id",
                  [slug, user_id]}
               ]) do
            {:ok, [_messages, [_room]]} -> send_json(conn, 200, %{deleted: true})
            {:ok, [_messages, []]} -> send_json(conn, 404, %{error: "not found"})
            {:error, _reason} -> send_json(conn, 500, %{error: "database error"})
          end
      end
    end

    post "/room_memberships" do
      with {:ok, slug} <- require_text(conn.params["room_slug"], 64),
           owner_id when not is_nil(owner_id) <- parse_id(conn.params["owner_id"]),
           user_id when not is_nil(user_id) <- parse_id(conn.params["user_id"]) do
        # One statement does all the checks: the room must exist and belong
        # to `owner_id`, the invitee must be a real account, and the owner
        # cannot be made a member of their own room. Any failure is a 404; a
        # repeat share trips the unique index and answers 409.
        ("INSERT INTO room_memberships (room_id, user_id) " <>
           "SELECT r.id, u.id FROM rooms r JOIN users u ON u.id = ?3 " <>
           "WHERE r.slug = ?1 AND r.user_id = ?2 AND u.id <> r.user_id " <>
           "RETURNING #{@membership_columns}")
        |> query([slug, owner_id, user_id])
        |> case do
          {:ok, [row]} -> send_json(conn, 201, %{membership: row})
          {:ok, []} -> send_json(conn, 404, %{error: "not found"})
          {:error, reason} -> send_db_error(conn, reason)
        end
      else
        _other ->
          send_json(conn, 400, %{error: "room_slug, owner_id and user_id are required"})
      end
    end

    delete "/room_memberships" do
      with {:ok, slug} <- require_text(conn.params["room_slug"], 64),
           user_id when not is_nil(user_id) <- parse_id(conn.params["user_id"]),
           actor_id when not is_nil(actor_id) <- parse_id(conn.params["actor_id"]) do
        # Two callers are legitimate: the owner revoking a member, and a
        # member removing themselves (leaving). Anyone else deletes zero rows.
        {:ok, rows} =
          LocalGateway.query(
            "DELETE FROM room_memberships " <>
              "WHERE room_id = (SELECT id FROM rooms WHERE slug = ?1) AND user_id = ?2 " <>
              "AND (?3 = ?2 OR EXISTS (SELECT 1 FROM rooms WHERE slug = ?1 AND user_id = ?3)) " <>
              "RETURNING id",
            [slug, user_id, actor_id]
          )

        send_json(conn, 200, %{deleted: length(rows)})
      else
        _other ->
          send_json(conn, 400, %{error: "room_slug, user_id and actor_id are required"})
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

    # Resolves a room slug for a viewer (`nil` when anonymous). No row means
    # the slug was never claimed — an implicit *link* room, open to anyone,
    # exactly as every room was before rooms became rows. A row grants
    # "owner" to its user_id, "member" to anyone in room_memberships, and
    # "link" to everyone else, which only suffices when the room's
    # visibility is "link".
    defp room_access(slug, viewer_id) do
      {:ok, rows} =
        query(
          "SELECT #{@room_columns}, EXISTS (SELECT 1 FROM room_memberships rm " <>
            "WHERE rm.room_id = rooms.id AND rm.user_id = ?2) AS is_member " <>
            "FROM rooms WHERE slug = ?1",
          [slug, viewer_id]
        )

      case rows do
        [] ->
          %{room: nil, allowed: true, role: "link"}

        [row] ->
          {is_member, room} = Map.pop(row, "is_member")

          role =
            cond do
              room["user_id"] == viewer_id -> "owner"
              is_member == 1 -> "member"
              true -> "link"
            end

          %{room: room, allowed: room["visibility"] == "link" or role != "link", role: role}
      end
    end

    # A viewer on the message and room read paths: absent (or JSON `null`)
    # means anonymous and is a legitimate value — link rooms serve anyone —
    # while a value that was sent but unusable is `:error`, answered 400.
    defp parse_viewer(nil), do: {:ok, nil}

    defp parse_viewer(value) do
      case parse_id(value) do
        nil -> :error
        id -> {:ok, id}
      end
    end

    defp require_visibility(value) when value in @room_visibilities, do: {:ok, value}
    defp require_visibility(_value), do: :error

    # The allowlist of columns `PATCH /rooms/:slug` may set. A JSON `null`
    # clears the name; for visibility it is invalid.
    defp room_updates(params) do
      [
        {"name",
         fn
           nil -> {:ok, nil}
           value -> require_text(value, @room_name_max_length)
         end},
        {"visibility", &require_visibility/1}
      ]
      |> Enum.reduce_while({:ok, []}, fn {column, parse}, {:ok, acc} ->
        case Map.fetch(params, column) do
          :error -> {:cont, {:ok, acc}}
          {:ok, value} -> continue_update(parse.(value), column, acc)
        end
      end)
    end

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
        send_json(conn, 409, %{error: "unique constraint violated"})
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
