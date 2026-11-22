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
    assert {:ok, applied} = LocalGateway.query("SELECT name FROM local_migrations ORDER BY name")

    # Compared against the directory rather than a hardcoded list, so adding a
    # migration cannot leave this test asserting yesterday's schema.
    on_disk =
      "../cloudflare/migrations/*.sql"
      |> Path.expand(File.cwd!())
      |> Path.wildcard()
      |> Enum.map(&Path.basename/1)
      |> Enum.sort()

    assert on_disk != []
    assert Enum.map(applied, & &1["name"]) == on_disk
  end

  test "messages round trip the way the Worker's gateway does" do
    # Messages reference `users (id)`, which SQLite enforces here as D1 does
    # remotely, so a message needs a real sender row.
    sender = create_user("ada@example.com")["id"]

    assert {201, %{"message" => created}} =
             request(:post, "/messages", %{
               room: "lobby",
               user_id: sender,
               nickname: "ada",
               body: "hello"
             })

    assert created["id"] == 1
    assert created["room"] == "lobby"
    assert created["user_id"] == sender
    assert created["inserted_at"]

    assert {200, %{"messages" => [message]}} = request(:get, "/messages?room=lobby")
    assert message["body"] == "hello"

    # Scoped per room, which is what makes shareable sessions separate.
    assert {200, %{"messages" => []}} = request(:get, "/messages?room=other")
  end

  test "returns messages oldest first, newest-limited" do
    sender = create_user("n@example.com")["id"]

    for body <- ~w(one two three) do
      assert {201, _body} =
               request(:post, "/messages", %{
                 room: "r",
                 user_id: sender,
                 nickname: "n",
                 body: body
               })
    end

    assert {200, %{"messages" => messages}} = request(:get, "/messages?room=r&limit=2")
    assert Enum.map(messages, & &1["body"]) == ["two", "three"]
  end

  test "rejects an invalid message" do
    sender = create_user("ada@example.com")["id"]

    assert {400, %{"error" => _error}} =
             request(:post, "/messages", %{
               room: "lobby",
               user_id: sender,
               nickname: "ada",
               body: "  "
             })

    # The sender is required, the way `user_id` is on every task route.
    assert {400, %{"error" => "user_id is required"}} =
             request(:post, "/messages", %{room: "lobby", nickname: "ada", body: "hello"})

    assert {400, %{"error" => "room is required"}} = request(:get, "/messages")
  end

  test "serves the tasks contract too" do
    # Tasks reference `users (id)`, and SQLite enforces that here as D1 does
    # remotely, so a task needs a real owner row.
    owner = create_user("owner@example.com")["id"]

    assert {201, %{"task" => task}} =
             request(:post, "/tasks", %{user_id: owner, title: "write it down"})

    assert task["completed"] == 0
    assert task["user_id"] == owner

    assert {200, %{"task" => updated}} =
             request(:patch, "/tasks/#{task["id"]}?user_id=#{owner}", %{completed: true})

    assert updated["completed"] == 1

    assert {200, %{"tasks" => [_task]}} = request(:get, "/tasks?user_id=#{owner}")

    assert {200, %{"deleted" => true}} =
             request(:delete, "/tasks/#{task["id"]}?user_id=#{owner}")

    assert {404, _body} = request(:get, "/tasks/#{task["id"]}?user_id=#{owner}")
  end

  test "scopes every task route to its user_id" do
    mine_id = create_user("mine@example.com")["id"]
    theirs_id = create_user("theirs@example.com")["id"]

    assert {201, %{"task" => mine}} =
             request(:post, "/tasks", %{user_id: mine_id, title: "mine"})

    assert {201, _body} = request(:post, "/tasks", %{user_id: theirs_id, title: "theirs"})

    assert {200, %{"tasks" => [task]}} = request(:get, "/tasks?user_id=#{mine_id}")
    assert task["title"] == "mine"

    # Another user's task is a 404, not a leak — and not writable either.
    path = "/tasks/#{mine["id"]}?user_id=#{theirs_id}"
    assert {404, _body} = request(:get, path)
    assert {404, _body} = request(:patch, path, %{title: "stolen"})
    assert {404, _body} = request(:delete, path)

    assert {200, %{"task" => unchanged}} =
             request(:get, "/tasks/#{mine["id"]}?user_id=#{mine_id}")

    assert unchanged["title"] == "mine"
  end

  test "requires a user_id on every task route" do
    assert {400, %{"error" => "user_id is required"}} = request(:get, "/tasks")

    assert {400, %{"error" => "user_id is required"}} =
             request(:post, "/tasks", %{title: "unowned"})

    assert {400, %{"error" => "user_id is required"}} = request(:get, "/tasks/1")
    assert {400, %{"error" => "user_id is required"}} = request(:patch, "/tasks/1", %{})
    assert {400, %{"error" => "user_id is required"}} = request(:delete, "/tasks/1")
  end

  test "404s an unknown path" do
    assert {404, %{"error" => "not found"}} = request(:get, "/nope")
  end

  describe "accounts contract" do
    @token String.duplicate("ab", 32)
    @other_token String.duplicate("cd", 32)

    defp create_user(email, attrs \\ %{}) do
      assert {201, %{"user" => user}} =
               request(:post, "/users", Map.merge(%{email: email}, attrs))

      user
    end

    test "users round trip and are matched case-insensitively" do
      user = create_user("Ada@Example.com", %{hashed_password: "hash"})

      assert user["id"] == 1
      assert user["email"] == "Ada@Example.com"
      assert user["confirmed_at"] == nil
      assert user["inserted_at"]

      # Stands in for the citext column the generated Postgres migration uses.
      assert {200, %{"user" => ^user}} = request(:get, "/users?email=ada@EXAMPLE.com")
      assert {200, %{"user" => ^user}} = request(:get, "/users/#{user["id"]}")
      assert {404, _body} = request(:get, "/users?email=nobody@example.com")
      assert {404, _body} = request(:get, "/users/2")
    end

    test "rejects a duplicate email, ignoring case" do
      create_user("ada@example.com")

      assert {409, %{"error" => error}} = request(:post, "/users", %{email: "ADA@example.com"})
      assert error =~ "already been taken"
    end

    test "rejects invalid user attributes" do
      assert {400, _body} = request(:post, "/users", %{email: "  "})
      assert {400, _body} = request(:post, "/users", %{email: String.duplicate("a", 161)})
      assert {400, _body} = request(:post, "/users", %{email: "a@b.c", confirmed_at: "nope"})
      assert {400, %{"error" => "email is required"}} = request(:get, "/users")
    end

    test "tokens round trip with their user" do
      user = create_user("ada@example.com")

      assert {201, %{"user_token" => created}} =
               request(:post, "/user_tokens", %{
                 user_id: user["id"],
                 token: @token,
                 context: "session",
                 authenticated_at: "2026-11-14 12:00:00"
               })

      assert created["token"] == @token
      assert created["authenticated_at"] == "2026-11-14 12:00:00"
      assert created["sent_to"] == nil

      assert {200, %{"user_token" => ^created, "user" => ^user}} =
               request(:get, "/user_tokens?token=#{@token}&context=session")

      # The context is part of the lookup, so a token is useless elsewhere.
      assert {404, _body} = request(:get, "/user_tokens?token=#{@token}&context=login")

      assert {200, %{"deleted" => 1}} =
               request(:delete, "/user_tokens?token=#{@token}&context=session")

      assert {200, %{"deleted" => 0}} =
               request(:delete, "/user_tokens?token=#{@token}&context=session")
    end

    test "rejects a token that is not 32 bytes of hex" do
      user = create_user("ada@example.com")

      assert {400, _body} =
               request(:post, "/user_tokens", %{
                 user_id: user["id"],
                 token: "not-hex",
                 context: "session"
               })

      assert {400, _body} = request(:get, "/user_tokens?token=short&context=session")
    end

    test "updates a user and expires their tokens in one transaction" do
      user = create_user("ada@example.com", %{hashed_password: "old"})

      for {token, context} <- [{@token, "session"}, {@other_token, "login"}] do
        assert {201, _body} =
                 request(:post, "/user_tokens", %{
                   user_id: user["id"],
                   token: token,
                   context: context
                 })
      end

      assert {200, %{"user" => updated, "expired_tokens" => expired}} =
               request(:patch, "/users/#{user["id"]}", %{
                 hashed_password: "new",
                 confirmed_at: "2026-11-14 12:00:00",
                 delete_all_tokens: true
               })

      assert updated["hashed_password"] == "new"
      assert updated["confirmed_at"] == "2026-11-14 12:00:00"
      assert Enum.map(expired, & &1["context"]) |> Enum.sort() == ["login", "session"]
      assert {404, _body} = request(:get, "/user_tokens?token=#{@token}&context=session")
    end

    test "expires only one context when asked" do
      user = create_user("ada@example.com")

      for {token, context} <- [{@token, "change:ada@example.com"}, {@other_token, "session"}] do
        assert {201, _body} =
                 request(:post, "/user_tokens", %{
                   user_id: user["id"],
                   token: token,
                   context: context
                 })
      end

      assert {200, %{"user" => updated, "expired_tokens" => [expired]}} =
               request(:patch, "/users/#{user["id"]}", %{
                 email: "ada@new.example.com",
                 delete_tokens_context: "change:ada@example.com"
               })

      assert updated["email"] == "ada@new.example.com"
      assert expired["token"] == @token

      # The session survives an email change, as it does in the generated code.
      assert {200, _body} = request(:get, "/user_tokens?token=#{@other_token}&context=session")
    end

    test "rolls the update back when the new email is taken" do
      create_user("taken@example.com")
      user = create_user("ada@example.com")

      assert {201, _body} =
               request(:post, "/user_tokens", %{
                 user_id: user["id"],
                 token: @token,
                 context: "session"
               })

      assert {409, _body} =
               request(:patch, "/users/#{user["id"]}", %{
                 email: "TAKEN@example.com",
                 delete_all_tokens: true
               })

      assert {200, %{"user" => unchanged}} = request(:get, "/users/#{user["id"]}")
      assert unchanged["email"] == "ada@example.com"
      assert {200, _body} = request(:get, "/user_tokens?token=#{@token}&context=session")
    end

    test "rejects an empty or invalid user update" do
      user = create_user("ada@example.com")

      assert {400, %{"error" => "no user attributes to update"}} =
               request(:patch, "/users/#{user["id"]}", %{delete_all_tokens: true})

      assert {400, _body} = request(:patch, "/users/#{user["id"]}", %{confirmed_at: "nope"})
      assert {400, _body} = request(:patch, "/users/nope", %{email: "a@b.c"})
      assert {404, _body} = request(:patch, "/users/99", %{email: "a@b.c"})
    end
  end
end
