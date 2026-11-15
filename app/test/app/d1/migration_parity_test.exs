defmodule App.D1.MigrationParityTest do
  @moduledoc """
  The schema has two expressions: the Ecto migrations in
  `priv/migration_repo/migrations/` (the authored source) and the exported
  `cloudflare/migrations/*.sql` (what Wrangler applies to D1 and
  `App.D1.LocalGateway` applies locally). This asserts the two build an
  identical schema, so an edit to either side that is not reflected in the
  other — a hand-tweaked `.sql`, a forgotten `mix d1.gen_migrations` —
  fails the suite instead of shipping a drift.
  """

  use ExUnit.Case

  alias App.D1.LocalGateway

  @schema_query """
  SELECT type, name, sql FROM sqlite_master
  WHERE name NOT LIKE 'sqlite_%' AND name NOT IN ('schema_migrations', 'local_migrations')
  """

  test "the Ecto migrations and the exported SQL build the same schema" do
    sql_database = scratch("parity_sql")
    ecto_database = scratch("parity_ecto")

    # Path A: the exported files, applied the way dev/test always apply
    # them (and the way Wrangler applies them to D1).
    migrations = Path.expand("../cloudflare/migrations", File.cwd!())
    start_supervised!({LocalGateway, port: 0, database: sql_database, migrations: migrations})
    {:ok, from_sql} = LocalGateway.query(@schema_query)

    # Path B: the authored Ecto migrations, run by Ecto's migrator.
    Application.put_env(:app, App.MigrationRepo, database: ecto_database, pool_size: 1)
    start_supervised!(App.MigrationRepo)

    Ecto.Migrator.run(App.MigrationRepo, [App.MigrationRepo.migrations_path()], :up, all: true)

    %{rows: from_ecto} = App.MigrationRepo.query!(@schema_query)

    from_ecto =
      Enum.map(from_ecto, fn [type, name, sql] ->
        %{"type" => type, "name" => name, "sql" => sql}
      end)

    assert normalize(from_sql) == normalize(from_ecto)
  end

  test "every authored migration has its exported file, and vice versa" do
    authored =
      App.MigrationRepo.migrations_path()
      |> Path.join("*.exs")
      |> Path.wildcard()
      |> Enum.map(&Path.basename(&1, ".exs"))
      |> Enum.sort()

    exported =
      Path.expand("../cloudflare/migrations", File.cwd!())
      |> Path.join("*.sql")
      |> Path.wildcard()
      |> Enum.map(&Path.basename(&1, ".sql"))
      |> Enum.sort()

    assert authored == exported,
           "authored (.exs) and exported (.sql) migrations differ — " <>
             "run `mix d1.gen_migrations` (or add the missing .exs)"
  end

  ## Helpers

  defp scratch(prefix) do
    database =
      Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}.sqlite3")

    on_exit(fn -> File.rm_rf!(database) end)
    database
  end

  # sqlite_master keeps the original statement text, so cosmetic differences
  # (whitespace, IF NOT EXISTS, identifier quoting, comments SQLite chose to
  # keep) are normalized away; everything structural — columns, types,
  # defaults, CHECKs, foreign keys, index expressions — must match exactly.
  defp normalize(rows) do
    rows
    |> Enum.map(fn %{"type" => type, "name" => name, "sql" => sql} ->
      {type, name, normalize_sql(sql)}
    end)
    |> Enum.sort()
  end

  defp normalize_sql(nil), do: nil

  defp normalize_sql(sql) do
    sql
    |> String.replace(~r/--[^\n]*/, " ")
    |> String.replace(~r/\bIF NOT EXISTS\b/i, " ")
    |> String.replace(~s("), "")
    |> String.replace("`", "")
    |> String.downcase()
    |> String.replace(~r/\s+/, " ")
    |> String.replace(~r/\s*([(),])\s*/, "\\1")
    |> String.trim()
  end
end
