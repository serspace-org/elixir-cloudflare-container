# Phoenix on Cloudflare Containers

A full Phoenix 1.8 LiveView application deployed as a Docker container on Cloudflare Containers, with a Cloudflare Worker + Durable Object as the proxy layer (including WebSocket support for LiveView).

This repo is a work in progress.

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
  - `App.Chat` — chat context over D1, broadcast with `Phoenix.PubSub` (`/chat` LiveView, `/probe` raw channel client)
  - `App.D1` — HTTP client for the Worker's private D1 gateway
- **`src/index.ts`** — Worker + Durable Object: container lifecycle, HTTP/WebSocket proxying, and the `D1Gateway` entrypoint
- **`cloudflare/migrations/`** — SQL migrations applied to D1 with Wrangler
- **`Dockerfile`** — Multi-stage build: compiles an Elixir release with assets, copies into minimal Alpine runtime
- **`wrangler.toml`** — Wrangler config (container, Durable Object, D1 binding)
- **`scripts/ws-smoke.mjs`** — post-deploy WebSocket/channel smoke test (`pnpm ws:smoke <url>`)
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

## Chat (WebSocket + Channels) demo

Phoenix's two socket paths are verified separately, because they fail differently:

| Route | Socket | What a failure tells you |
| --- | --- | --- |
| `/chat` | LiveView on `/live` | LiveView real-time updates |
| `/probe` | raw `Phoenix.Channel` on `/socket`, **no long-poll fallback** | the WebSocket upgrade itself |

The reason for two is that `assets/js/app.js` sets `longPollFallbackMs`, so a broken
WebSocket upgrade makes LiveView quietly fall back to long-polling and *everything still
looks fine*. `/socket` sets `longpoll: false`, and both pages print the transport actually
in use, so a degraded connection is visible rather than invisible.

### What to check

```bash
pnpm ws:smoke https://<your-host>   # scripted: handshake, join, broadcast round trip

curl https://<your-host>/health/sockets
# {"status":"ok","node":"...","node_uptime_ms":123456,"present":0,"d1_ready":true,...}
```

By hand, open `/chat` and `/probe` side by side:

1. **Transport** on both pages must say `websocket`. `/chat` turns the card red and says so
   explicitly if the LiveView socket degraded to long-polling.
2. **Cross-socket fan-out** — a message sent in `/probe` must appear in `/chat` and vice
   versa. That exercises `Phoenix.PubSub` between two different socket implementations.
3. **Presence** — *Online now* must rise and fall as you open and close tabs.
4. **Round trip** on `/probe` is the real latency through Worker → Durable Object →
   container.
5. **Node uptime** is the one to watch on a reconnect: if it *keeps climbing*, only the
   socket reconnected; if it *resets to zero*, the container cold-started and you lost BEAM
   state. Persisted history survives either way, which is the point of storing it in D1.
6. **Idle survival** — leave a tab open and idle for more than 10 minutes (the Durable
   Object's `INACTIVITY_TIMEOUT_MS`). Phoenix heartbeats every 30s, so the socket should
   stay up and node uptime should keep climbing. If it does not, WebSocket traffic is not
   counting as container activity and the timeout needs raising or a keepalive adding.

Without a D1 binding — plain `mix phx.server`, for instance — chat still works but marks
itself *ephemeral* and does not persist history, so the transport can be tested on its own.

## Notes

- Container instance type is `basic` (1 GiB RAM)
- Container sleeps after 10 minutes of inactivity (configurable via `INACTIVITY_TIMEOUT_MS` in `src/index.ts`)
- Disk is **ephemeral** — durable state lives in D1
- The Worker handles TLS; the container serves plain HTTP behind it
- `force_ssl` uses `x-forwarded-proto` and excludes `/health`
- WebSocket upgrades are forwarded transparently to the container, for both LiveView and plain channels
- Every request is routed to a single Durable Object (`getByName("singleton")`), so all sockets share one BEAM node and local `Phoenix.PubSub` is sufficient — sharding the DO would split chat and presence per instance
- Asset pipeline: esbuild + tailwind are Elixir-managed (no Node.js needed in the Docker build)