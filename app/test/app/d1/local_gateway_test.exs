defmodule App.D1.LocalGatewayTest do
  @moduledoc """
  Exercises the local D1 stand-in against the real `cloudflare/migrations`
  files, so this doubles as a check that the migrations apply cleanly and
  that the local gateway's SQL matches the Worker's `D1Gateway` contract.
  """

  use ExUnit.Case

  import Plug.Test
  import Plug.Conn

  alias App.D1.LocalGateway

  @opts LocalGateway.Router.init([])

  setup do
    # mix test runs from app/, and the migrations live at the repo root.
    migrations = Path.expand("../cloudflare/migrations", File.cwd!())

    database =
      Path.join(System.tmp_dir!(), "d1_local_test_#{System.unique_integer([:positive])}.sqlite3")

    on_exit(fn -> File.rm_rf!(database) end)

    start_supervised!({LocalGateway, port: 0, database: database, migrations: migrations})
    :ok
  end

  defp request(method, path, body \\ nil) do
    conn =
      case body do
        nil ->
          conn(method, path)

        body ->
          conn(method, path, Jason.encode!(body))
          |> put_req_header("content-type", "application/json")
      end

    conn = LocalGateway.Router.call(conn, @opts)
    {conn.status, Jason.decode!(conn.resp_body)}
  end

  test "applies the repo's migrations" do
    assert {:ok, [%{"name" => "0001_create_tasks.sql"}, %{"name" => "0002_create_messages.sql"}]} =
             LocalGateway.query("SELECT name FROM local_migrations ORDER BY name")
  end

  test "messages round trip the way the Worker's gateway does" do
    assert {201, %{"message" => created}} =
             request(:post, "/messages", %{room: "lobby", nickname: "ada", body: "hello"})

    assert created["id"] == 1
    assert created["room"] == "lobby"
    assert created["inserted_at"]

    assert {200, %{"messages" => [message]}} = request(:get, "/messages?room=lobby")
    assert message["body"] == "hello"

    # Scoped per room, which is what makes shareable sessions separate.
    assert {200, %{"messages" => []}} = request(:get, "/messages?room=other")
  end

  test "returns messages oldest first, newest-limited" do
    for body <- ~w(one two three) do
      assert {201, _body} = request(:post, "/messages", %{room: "r", nickname: "n", body: body})
    end

    assert {200, %{"messages" => messages}} = request(:get, "/messages?room=r&limit=2")
    assert Enum.map(messages, & &1["body"]) == ["two", "three"]
  end

  test "rejects an invalid message" do
    assert {400, %{"error" => _error}} =
             request(:post, "/messages", %{room: "lobby", nickname: "ada", body: "  "})

    assert {400, %{"error" => "room is required"}} = request(:get, "/messages")
  end

  test "serves the tasks contract too" do
    assert {201, %{"task" => task}} = request(:post, "/tasks", %{title: "write it down"})
    assert task["completed"] == 0

    assert {200, %{"task" => updated}} =
             request(:patch, "/tasks/#{task["id"]}", %{completed: true})

    assert updated["completed"] == 1

    assert {200, %{"tasks" => [_task]}} = request(:get, "/tasks")
    assert {200, %{"deleted" => true}} = request(:delete, "/tasks/#{task["id"]}")
    assert {404, _body} = request(:get, "/tasks/#{task["id"]}")
  end

  test "404s an unknown path" do
    assert {404, %{"error" => "not found"}} = request(:get, "/nope")
  end
end
