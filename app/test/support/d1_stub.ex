defmodule App.D1Stub do
  @moduledoc """
  `Req.Test` stubs for the private D1 gateway.

  `App.D1` talks to the gateway over HTTP, and `config/test.exs` points its
  Req options at `{Req.Test, App.D1}`, so tests answer those calls here
  instead of reaching `d1.internal`.

  Tests using these helpers must run in shared `Req.Test` mode (the default
  for non-async cases), because the process making the call is usually a
  channel or LiveView process rather than the test process.
  """

  @doc "Stubs the gateway with `fun`, a Plug-style function receiving a conn."
  def stub_d1(fun) when is_function(fun, 1) do
    Req.Test.stub(App.D1, fun)
  end

  @doc """
  Backs `App.D1` with a real SQLite database for the duration of one test.

  Hand-written stubs are fine for a route or two, but the accounts context
  leans on SQL the gateway actually has to run — a unique index on
  `lower(email)`, `RETURNING`, a batched update-and-delete. So instead of
  faking those, this points the stub at `App.D1.LocalGateway.Router`, the same
  plug `mix phx.server` talks to, over a throwaway database built from
  `cloudflare/migrations`. Each test gets its own file, which is what the Ecto
  sandbox would have given us.

  Usable directly as a setup callback:

      setup :stub_d1_sqlite!

  Only for `async: false` cases: the gateway is a named process, and the stub
  has to be visible from LiveView and channel processes.
  """
  def stub_d1_sqlite!(_context \\ %{}) do
    # mix test runs from app/, and the migrations live at the repo root.
    migrations = Path.expand("../cloudflare/migrations", File.cwd!())

    database =
      Path.join(System.tmp_dir!(), "d1_stub_#{System.unique_integer([:positive])}.sqlite3")

    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(database) end)

    ExUnit.Callbacks.start_supervised!(
      {App.D1.LocalGateway, port: 0, database: database, migrations: migrations}
    )

    opts = App.D1.LocalGateway.Router.init([])
    stub_d1(fn conn -> App.D1.LocalGateway.Router.call(conn, opts) end)

    :ok
  end

  @doc """
  Stubs the gateway with an in-memory message store.

  Returns the agent pid holding the rows so a test can assert on what was
  actually persisted.
  """
  def stub_d1_messages(initial \\ []) do
    {:ok, store} = Agent.start_link(fn -> initial end)

    stub_d1(fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/messages"} ->
          Req.Test.json(conn, %{"messages" => Agent.get(store, & &1)})

        {"POST", "/messages"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          params = Jason.decode!(body)

          row =
            Agent.get_and_update(store, fn rows ->
              row =
                Map.merge(params, %{
                  "id" => length(rows) + 1,
                  "inserted_at" => "2026-11-13T00:00:00"
                })

              {row, rows ++ [row]}
            end)

          conn
          |> Plug.Conn.put_status(201)
          |> Req.Test.json(%{"message" => row})

        _other ->
          conn
          |> Plug.Conn.put_status(404)
          |> Req.Test.json(%{"error" => "not found"})
      end
    end)

    store
  end

  @doc "Returns the rows held by a store from `stub_d1_messages/1`."
  def persisted_messages(store), do: Agent.get(store, & &1)

  @doc "Stubs the gateway as unreachable, the way local dev behaves."
  def stub_d1_unavailable do
    stub_d1(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)
  end
end
