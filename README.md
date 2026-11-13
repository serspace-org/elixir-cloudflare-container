# Phoenix on Cloudflare Containers

A full Phoenix 1.8 LiveView application deployed as a Docker container on Cloudflare Containers, with a Cloudflare Worker + Durable Object as the proxy layer (including WebSocket support for LiveView).

## Architecture

```
Client (HTTPS) → Cloudflare Worker → Durable Object → Container (Phoenix on :4000)
                                                        ↓
                                            Private D1 gateway (Worker)
                                                        ↓
                                              Cloudflare D1 database
```

The Worker starts the container on first request, polls `/health` until it's ready, then proxies all HTTP and WebSocket traffic to the Phoenix app on port 4000.

Database access goes through a private gateway inside the Worker: Phoenix makes plain HTTP requests to the virtual hostname `d1.internal`, which the Worker intercepts and serves with its `DB` D1 binding (see `D1Gateway` in `src/index.ts`). The database is never exposed to the public internet and no database credentials ship in the container image.

## What's here

- **`app/`** — Phoenix 1.8.5 app (LiveView, Ecto, Bandit, Swoosh, Tailwind, esbuild)
  - `App.Tasks` — CRUD context over D1 (`/tasks` LiveView)
  - `App.D1` — HTTP client for the Worker's private D1 gateway
- **`src/index.ts`** — Worker + Durable Object: container lifecycle, HTTP/WebSocket proxying, and the `D1Gateway` entrypoint
- **`cloudflare/migrations/`** — SQL migrations applied to D1 with Wrangler
- **`Dockerfile`** — Multi-stage build: compiles an Elixir release with assets, copies into minimal Alpine runtime
- **`wrangler.toml`** — Wrangler config (container, Durable Object, D1 binding)
- **`.github/workflows/deploy.yml`** — CI workflow that deploys on push to `main`

## Prerequisites

- Cloudflare Workers **Paid** plan (required for Containers)
- GitHub repo secrets: `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`

## Setup

### 1. Wrangler secrets

```bash
npx wrangler secret put SECRET_KEY_BASE   # output of: mix phx.gen.secret
npx wrangler secret put PHX_HOST           # e.g. phoenix-cf-container.serspace.dev
```

### 2. Database (Cloudflare D1)

```bash
pnpm exec wrangler d1 create phoenix-cf-container-db
```

Uncomment the `[[d1_databases]]` block at the bottom of `wrangler.toml` and paste the printed `database_id`. Then apply the migration:

```bash
# Test against a local D1 first (optional):
pnpm exec wrangler d1 migrations apply phoenix-cf-container-db --local

# Apply to production:
pnpm exec wrangler d1 migrations apply phoenix-cf-container-db --remote
```

Until the binding is configured, `/tasks` shows a setup notice and everything else keeps working — the gateway activates only when the `DB` binding exists.

### 3. GitHub repo secrets

In your GitHub repo settings, add:

- `CLOUDFLARE_API_TOKEN` — a Cloudflare API token with Workers and Containers permissions
- `CLOUDFLARE_ACCOUNT_ID` — your Cloudflare account ID

## Deploy

### Via CI (recommended)

Push to the `main` branch. GitHub Actions builds the Docker image on native AMD64 (`ubuntu-latest`), pushes it to Cloudflare's registry, and deploys the Worker. The first deploy takes 5–10 minutes for the image build.

### Locally

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

**Apply a migration before deploying code that depends on it**, and keep migrations additive (new tables/columns) while the previous version is still serving traffic. Wrangler records applied migrations in D1's `d1_migrations` table.

Note: D1 is not an Ecto repo. `App.Tasks` validates changes with the `App.Tasks.Task` embedded schema and persists through `App.D1`; `mix ecto.*` tasks do not apply.

## Test

```bash
curl https://<your-host>/
curl https://<your-host>/health
# ok
```

Then open `/tasks` for the D1-backed CRUD demo.

The first request may take 5–15 seconds (container cold start). Subsequent requests are instant while the container is warm.

## Notes

- Container instance type is `basic` (1 GiB RAM)
- Container sleeps after 10 minutes of inactivity (configurable via `INACTIVITY_TIMEOUT_MS` in `src/index.ts`)
- Disk is **ephemeral** — durable state lives in D1
- The Worker handles TLS; the container serves plain HTTP behind it
- `force_ssl` uses `x-forwarded-proto` and excludes `/health`
- WebSocket upgrades are forwarded transparently to the container for LiveView real-time updates
- Asset pipeline: esbuild + tailwind are Elixir-managed (no Node.js needed in the Docker build)
