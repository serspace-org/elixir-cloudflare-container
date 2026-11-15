# Deploying

## Via CI (recommended)

Push to the `main` branch. GitHub Actions applies any pending D1 migrations, then builds the Docker image on native AMD64 (`ubuntu-latest`), pushes it to Cloudflare's registry, and deploys the Worker. The first deploy takes 5–10 minutes for the image build. If the `SMOKE_URL` repo variable is set, the WebSocket smoke test runs against the deployment afterwards and fails the build if the socket is broken.

Migrations run **before** the deploy on purpose, so code can never ship ahead of its schema. If a migration fails, the deploy never happens. This means `CLOUDFLARE_API_TOKEN` needs D1 edit permission alongside Workers and Containers.

## How a deploy actually reaches users

Worker code goes live the moment `wrangler deploy` finishes, but the **container does not**: the Durable Object skips `start()` whenever one is already running, and the only thing that stops it is the inactivity timeout — which every single request pushes another 10 minutes out. Left alone, a deploy on a site with steady traffic may never take effect, and nothing looks wrong: the deploy is green, the old image keeps answering, and routes added in that deploy return 404.

So the DO records the image it started in its own storage and compares it on each request (`rollStaleContainer` in `src/index.ts`). When a deploy changes the image, the first request afterwards stops the old container so the next start picks up the new one. The cost is one cold start (5–15s) on that request, and in-flight WebSockets are dropped — LiveView reconnects on its own, and a deploy is the one moment that is worth it.

## Locally

```bash
pnpm install
pnpm exec wrangler deploy
```

**Note:** On Apple Silicon Macs, the Docker build uses QEMU emulation which crashes the BEAM VM when compiling Phoenix dependencies. Use CI (`ubuntu-latest` = native AMD64) instead. Local deploy works on Intel Macs and Linux.

## Schema changes (D1 migrations)

Migrations are **authored with the Ecto migration system and exported to SQL**. D1 is SQLite, so the Ecto migrator runs the migration against a scratch SQLite database (via `ecto_sqlite3`, a dev/test-only dep) and the SQL it executes is exported as the versioned file Wrangler applies:

```bash
cd app
mix ecto.gen.migration -r App.MigrationRepo add_whatever   # 1. the normal Phoenix generator
# ... edit the generated migration like any Ecto migration ...
mix d1.gen_migrations    # 2. export cloudflare/migrations/<version>_add_whatever.sql
mix test                 # 3. the parity test proves both paths build the same schema

pnpm exec wrangler d1 migrations apply phoenix-cf-container-db --remote   # by hand, rarely needed
just migrate-local       # the same thing against the local D1, by binding name
```

The generator's timestamped versions sort after the original `000N` files in every applier (Wrangler, the local gateway, Ecto's migrator), so the two naming styles coexist; just don't hand-number new files below the timestamps.

Commit the `.exs` and the exported `.sql` together. **Never edit or regenerate a `.sql` that already shipped** — D1 (and the local gateway) track applied migrations by file name, so a changed file is either skipped silently or breaks the deploy; the exporter refuses to overwrite existing files for this reason. `App.D1.MigrationParityTest` fails the suite if the authored migrations and the exported SQL ever disagree. (Don't use `wrangler d1 migrations create` — it would make a `.sql` with no authored source.)

CI applies pending migrations before each deploy (see `.github/workflows/deploy.yml`), so pushing a migration and the code that needs it in the same commit is safe. Run the `--remote` command by hand only when you need the schema live ahead of a deploy. Wrangler records applied migrations in D1's `d1_migrations` table and the command is idempotent, so re-running it is harmless.

**Keep migrations additive** (new tables and columns) while the previous version is still serving traffic: the old code keeps running for the length of the deploy, and the new schema has to be compatible with it. This is the same constraint any migrate-then-deploy pipeline has.

A new table or endpoint touches four places, which have to stay in step: the migration, a route in `D1Gateway` (`src/index.ts`), a client function in `app/lib/app/d1.ex`, and the same route in `App.D1.LocalGateway.Router`. The `tasks`, `messages`, `users` and `users_tokens` tables are all wired this way — copy any of them. Keep all SQL parameterized (`?1`-style binds).

Note: D1 is not an Ecto repo at *runtime* — there is no Ecto adapter for D1. `App.Tasks`, `App.Chat` and `App.Accounts` validate with embedded schemas and persist through `App.D1`; `mix ecto.migrate` never touches D1. Ecto's role is the authoring step above: migrations are written as Ecto migrations and exported to the SQL that Wrangler actually applies.

## Verifying a deployment

```bash
curl https://<your-host>/
curl https://<your-host>/health
# ok
```

`just smoke https://<your-host>` runs the scripted checks — WebSocket handshake, channel join, broadcast round trip, and the form-POST redirect. Then register at `/users/register` and open `/tasks` for the D1-backed CRUD demo — tasks belong to the user who created them — and `/chat` for the WebSocket demo, which needs no account.

The first request may take 5–15 seconds (container cold start). Subsequent requests are instant while the container is warm.
