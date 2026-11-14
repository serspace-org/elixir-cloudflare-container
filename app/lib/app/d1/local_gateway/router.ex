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

    @task_columns "id, title, completed, inserted_at, updated_at"
    @message_columns "id, room, nickname, body, inserted_at"
    @message_limit_default 50
    @message_limit_max 200

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

      if is_nil(room) or is_nil(nickname) or is_nil(body) do
        send_json(conn, 400, %{
          error: "room, nickname and body must be non-empty strings within their length limits"
        })
      else
        {:ok, [row]} =
          LocalGateway.query(
            "INSERT INTO messages (room, nickname, body) VALUES (?1, ?2, ?3) " <>
              "RETURNING #{@message_columns}",
            [room, nickname, body]
          )

        send_json(conn, 201, %{message: row})
      end
    end

    ## Tasks

    get "/tasks" do
      {:ok, rows} =
        LocalGateway.query(
          "SELECT #{@task_columns} FROM tasks ORDER BY inserted_at DESC, id DESC",
          []
        )

      send_json(conn, 200, %{tasks: rows})
    end

    post "/tasks" do
      case to_text(conn.params["title"], 255) do
        nil ->
          send_json(conn, 400, %{
            error: "title must be a non-empty string of at most 255 characters"
          })

        title ->
          {:ok, [row]} =
            LocalGateway.query(
              "INSERT INTO tasks (title, completed) VALUES (?1, 0) RETURNING #{@task_columns}",
              [title]
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
                "WHERE id = ?3 RETURNING #{@task_columns}",
              [title, if(completed, do: 1, else: 0), current["id"]]
            )

          send_json(conn, 200, %{task: row})
        end
      end)
    end

    delete "/tasks/:id" do
      case parse_id(id) do
        nil ->
          send_json(conn, 400, %{error: "invalid task id"})

        task_id ->
          case LocalGateway.query("DELETE FROM tasks WHERE id = ?1 RETURNING id", [task_id]) do
            {:ok, [_row]} -> send_json(conn, 200, %{deleted: true})
            {:ok, []} -> send_json(conn, 404, %{error: "not found"})
          end
      end
    end

    match _ do
      send_json(conn, 404, %{error: "not found"})
    end

    ## Helpers

    defp with_task(conn, id, fun) do
      case parse_id(id) do
        nil ->
          send_json(conn, 400, %{error: "invalid task id"})

        task_id ->
          case LocalGateway.query("SELECT #{@task_columns} FROM tasks WHERE id = ?1", [task_id]) do
            {:ok, [row]} -> fun.(row)
            {:ok, []} -> send_json(conn, 404, %{error: "not found"})
          end
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
