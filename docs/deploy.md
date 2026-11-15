# Deploying

## Via CI (recommended)

Push to the `main` branch. GitHub Actions applies any pending D1 migrations, then builds the Docker image on native AMD64 (`ubuntu-latest`), pushes it to Cloudflare's registry, and deploys the Worker. The first deploy takes 5–10 minutes for the image build. If the `SMOKE_URL` repo variable is set, the WebSocket smoke test runs against the deployment afterwards and fails the build if the socket is broken.

Migrations run **before** the deploy on purpose, so code can never ship ahead of its schema. If a migration fails, the deploy never happens. This means `CLOUDFLARE_API_TOKEN` needs D1 edit permission alongside Workers and Containers.

## How a deploy actually reaches users

Worker code goes live the moment `wrangler deploy` finishes, but the **container does not**: the Durable Object skips `start()` whenever one is already running, and the only thing that stops it is the inactivity timeout — which every single request pushes another 10 minutes out. Left alone, a deploy on a site with steady traffic may never take effect, and nothing looks wrong: the deploy is green, the old image keeps answering, and routes added in that deploy return 404.

So the DO records the image it started in its own storage and compares it on each request (`rollStaleContainer` in `src/index.ts`). When a deploy changes the image, the first request afterwards stops the old container so the next start picks up the new one. The cost is one cold start (5–15s) on that request, and in-flight WebSockets are dropped — LiveView reconnects on its own, and a deploy is the one moment that is worth it.

## Locally

```bash
npm install
npx wrangler deploy
```

**Note:** On Apple Silicon Macs, the Docker build uses QEMU emulation which crashes the BEAM VM when compiling Phoenix dependencies. Use CI (`ubuntu-latest` = native AMD64) instead. Local deploy works on Intel Macs and Linux.

## Schema changes (D1 migrations)

Migrations are versioned SQL files in `cloudflare/migrations/`, applied with Wrangler:

```bash
pnpm exec wrangler d1 migrations create phoenix-cf-container-db <name>
pnpm exec wrangler d1 migrations apply phoenix-cf-container-db --remote
```

CI applies pending migrations before each deploy (see `.github/workflows/deploy.yml`), so pushing a migration and the code that needs it in the same commit is safe. Run the `--remote` command by hand only when you need the schema live ahead of a deploy. Wrangler records applied migrations in D1's `d1_migrations` table and the command is idempotent, so re-running it is harmless.

**Keep migrations additive** (new tables and columns) while the previous version is still serving traffic: the old code keeps running for the length of the deploy, and the new schema has to be compatible with it. This is the same constraint any migrate-then-deploy pipeline has.

A new table or endpoint touches four places, which have to stay in step: the migration, a route in `D1Gateway` (`src/index.ts`), a client function in `app/lib/app/d1.ex`, and the same route in `App.D1.LocalGateway.Router`. The `tasks`, `messages`, `users` and `users_tokens` tables are all wired this way — copy any of them. Keep all SQL parameterized (`?1`-style binds).

Note: D1 is not an Ecto repo. `App.Tasks`, `App.Chat` and `App.Accounts` validate with embedded schemas and persist through `App.D1`; `mix ecto.*` tasks do not apply.

## Verifying a deployment

```bash
curl https://<your-host>/
curl https://<your-host>/health
# ok
```

Then open `/tasks` for the D1-backed CRUD demo and `/chat` for the WebSocket demo.

The first request may take 5–15 seconds (container cold start). Subsequent requests are instant while the container is warm.
