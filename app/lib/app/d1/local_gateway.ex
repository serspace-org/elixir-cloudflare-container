# Compiled outside :prod only — Exqlite is a dev/test dependency, and the
# production database is the real D1 gateway in the Worker.
if Mix.env() != :prod do
  defmodule App.D1.LocalGateway do
    @moduledoc """
    Local stand-in for the Worker's `D1Gateway`, so the app can be run and
    tested with real persistence without Docker or `wrangler dev`.

    D1 is SQLite, so this serves the same HTTP contract (`/tasks`,
    `/messages`) from a local SQLite file, applying the very same
    `cloudflare/migrations/*.sql` files Wrangler applies to D1. That makes it
    a check on the migrations themselves, not just a convenience.

    Enabled by `config :app, :d1_local_gateway, ...` (see `config/dev.exs`),
    which also points `:d1_url` at it. It is **not** a substitute for testing
    against `wrangler dev`: it exercises the SQL and the HTTP contract, not
    the `d1.internal` outbound intercept or Cloudflare's D1 itself.

    Writes are serialized through this GenServer, which matches SQLite's
    single-writer model.
    """

    use GenServer

    alias Exqlite.Sqlite3

    require Logger

    @migrations_table "local_migrations"

    @doc """
    Child specs for the gateway and the HTTP server in front of it.

    Called through a module attribute in `App.Application` so production
    never compiles a reference to this module.
    """
    def children(opts) do
      port = Keyword.fetch!(opts, :port)

      [
        {__MODULE__, opts},
        {Bandit, plug: App.D1.LocalGateway.Router, port: port, ip: {127, 0, 0, 1}}
      ]
    end

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end

    @doc """
    Runs `sql` with `params` and returns `{:ok, [row_map]}`.

    Column names come from the statement, so callers get the same string-keyed
    maps `App.D1` receives from the real gateway.
    """
    def query(sql, params \\ []) do
      GenServer.call(__MODULE__, {:query, sql, params})
    end

    @doc """
    Runs `statements` — `{sql, params}` tuples — in one transaction.

    The local counterpart of D1's `db.batch/1`, which is itself a single
    implicit transaction. Returns `{:ok, [rows_per_statement]}`, or rolls back
    and returns `{:error, reason}` if any statement fails.
    """
    def transaction(statements) when is_list(statements) do
      GenServer.call(__MODULE__, {:transaction, statements})
    end

    @doc "True when `reason` is a unique index violation."
    def unique_violation?(reason) when is_binary(reason) do
      String.contains?(reason, "UNIQUE constraint failed")
    end

    def unique_violation?(_reason), do: false

    @impl true
    def init(opts) do
      database = Keyword.fetch!(opts, :database)
      File.mkdir_p!(Path.dirname(database))

      {:ok, conn} = Sqlite3.open(database)
      :ok = Sqlite3.execute(conn, "PRAGMA foreign_keys = ON")
      apply_migrations(conn, Keyword.fetch!(opts, :migrations))

      Logger.info("local D1 gateway using #{database}")
      {:ok, %{conn: conn}}
    end

    @impl true
    def handle_call({:query, sql, params}, _from, %{conn: conn} = state) do
      {:reply, run(conn, sql, params), state}
    end

    def handle_call({:transaction, statements}, _from, %{conn: conn} = state) do
      :ok = Sqlite3.execute(conn, "BEGIN IMMEDIATE")

      result =
        Enum.reduce_while(statements, {:ok, []}, fn {sql, params}, {:ok, acc} ->
          case run(conn, sql, params) do
            {:ok, rows} -> {:cont, {:ok, [rows | acc]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      case result do
        {:ok, results} ->
          :ok = Sqlite3.execute(conn, "COMMIT")
          {:reply, {:ok, Enum.reverse(results)}, state}

        {:error, reason} ->
          :ok = Sqlite3.execute(conn, "ROLLBACK")
          {:reply, {:error, reason}, state}
      end
    end

    @impl true
    def terminate(_reason, %{conn: conn}), do: Sqlite3.close(conn)

    ## Migrations

    defp apply_migrations(conn, path) do
      :ok =
        Sqlite3.execute(conn, """
        CREATE TABLE IF NOT EXISTS #{@migrations_table} (
          name TEXT PRIMARY KEY,
          applied_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
        )
        """)

      {:ok, applied} = run(conn, "SELECT name FROM #{@migrations_table}", [])
      applied = MapSet.new(applied, & &1["name"])

      path
      |> Path.join("*.sql")
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.reject(&MapSet.member?(applied, Path.basename(&1)))
      |> Enum.each(fn file ->
        name = Path.basename(file)
        Logger.info("applying local D1 migration #{name}")
        :ok = Sqlite3.execute(conn, File.read!(file))
        {:ok, _rows} = run(conn, "INSERT INTO #{@migrations_table} (name) VALUES (?1)", [name])
      end)
    end

    ## Query execution

    defp run(conn, sql, params) do
      case Sqlite3.prepare(conn, sql) do
        {:ok, statement} ->
          # Released even when the statement fails, so a rollback inside
          # `transaction/1` is never blocked by a statement left open.
          try do
            with :ok <- Sqlite3.bind(statement, params),
                 {:ok, columns} <- Sqlite3.columns(conn, statement),
                 {:ok, rows} <- Sqlite3.fetch_all(conn, statement) do
              {:ok, Enum.map(rows, &row_map(columns, &1))}
            end
          after
            Sqlite3.release(conn, statement)
          end

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp row_map(columns, values) do
      columns |> Enum.zip(values) |> Map.new()
    end
  end
end
