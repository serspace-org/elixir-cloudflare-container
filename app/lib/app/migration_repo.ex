# Compiled outside :prod only, like App.D1.LocalGateway: production has no
# SQLite and no Ecto adapter exists for Cloudflare D1.
if Mix.env() != :prod do
  defmodule App.MigrationRepo do
    @moduledoc """
    The Ecto repo the D1 migrations are *authored* against.

    D1 has no Ecto adapter, so `mix ecto.migrate` can never reach the
    production database — Wrangler applies `cloudflare/migrations/*.sql`
    there (CI does it before every deploy). What this repo provides is the
    authoring path: schema changes are written as ordinary Ecto migrations
    in `priv/migration_repo/migrations/`, and `mix d1.gen_migrations` runs
    them through `Ecto.Migrator` against a scratch SQLite database (the
    same engine D1 runs) and emits the captured DDL as the `.sql` files
    Wrangler and `App.D1.LocalGateway` consume.

    So the `.exs` migrations are the source of truth and the `.sql` files
    are generated artifacts — but the artifacts are what production runs,
    which is why `App.D1.MigrationParityTest` asserts both paths produce an
    identical schema. Never edit a generated `.sql` by hand, and never
    regenerate one that already shipped: D1 tracks applied migrations by
    file name, so a changed file would either be skipped silently or break
    the deploy.

    This repo is never supervised; `mix d1.gen_migrations` and the parity
    test start it against a throwaway database and throw it away after.
    """

    use Ecto.Repo, otp_app: :app, adapter: Ecto.Adapters.SQLite3

    @doc "Where the authored Ecto migrations live."
    def migrations_path do
      Path.join([Application.app_dir(:app), "priv", "migration_repo", "migrations"])
    end
  end
end
