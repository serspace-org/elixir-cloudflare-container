# Phoenix on Cloudflare Containers

A full Phoenix 1.8 LiveView application deployed as a Docker container on Cloudflare Containers, with a Cloudflare Worker + Durable Object as the proxy layer (including WebSocket support for LiveView).

## Architecture

```
Client (HTTPS) → Cloudflare Worker → Durable Object → Container (Phoenix on :4000)
                                                        ↓
                                              External Postgres (Neon/Supabase)
```

The Worker starts the container on first request, polls `/health` until it's ready, then proxies all HTTP and WebSocket traffic to the Phoenix app on port 4000. The container has internet access to reach an external Postgres database.

## What's here

- **`app/`** — Full Phoenix 1.8.5 app (LiveView, Ecto/Postgrex, Bandit, Swoosh, Tailwind, esbuild)
- **`src/index.ts`** — Cloudflare Worker + Durable Object: container lifecycle, HTTP proxying, WebSocket forwarding
- **`Dockerfile`** — Multi-stage build: compiles an Elixir release with assets, copies into minimal Alpine runtime
- **`wrangler.toml`** — Wrangler config binding the container to a Durable Object
- **`.github/workflows/deploy.yml`** — CI workflow that deploys on push to `main`

## Prerequisites

- Cloudflare Workers **Paid** plan (required for Containers)
- An external Postgres database (recommended: [Neon](https://neon.tech) or [Supabase](https://supabase.com))
- GitHub repo secrets: `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`

## Setup

### 1. Create an external Postgres database

Create a database on Neon or Supabase and note the connection string:

```
ecto://USER:PASSWORD@HOST:5432/DATABASE
```

### 2. Set Wrangler secrets

These are passed as environment variables to the container at startup:

```bash
# Generate a secret key base
mix phx.gen.secret

# Set each secret
npx wrangler secret put SECRET_KEY_BASE
npx wrangler secret put DATABASE_URL
npx wrangler secret put PHX_HOST
```

- `SECRET_KEY_BASE` — output of `mix phx.gen.secret`
- `DATABASE_URL` — your Postgres connection string
- `PHX_HOST` — your deployment hostname (e.g. `phoenix-cf-container.YOUR-SUBDOMAIN.workers.dev`)

### 3. Set GitHub repo secrets

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

## Test

```bash
curl https://phoenix-cf-container.YOUR-SUBDOMAIN.workers.dev/
curl https://phoenix-cf-container.YOUR-SUBDOMAIN.workers.dev/health
# ok
```

The first request may take 5–15 seconds (cold start: container boot + Phoenix startup + database migration). Subsequent requests are instant while the container is warm.

## Notes

- Container instance type is `basic` (1 GiB RAM) — the `lite` tier (256 MiB) is too small for Phoenix
- Container sleeps after 10 minutes of inactivity (configurable via `INACTIVITY_TIMEOUT_MS` in `src/index.ts`)
- Disk is **ephemeral** — all state lives in the external Postgres database
- The Worker handles TLS; the container serves plain HTTP behind it
- `force_ssl` in the Phoenix config uses `x-forwarded-proto` (set by Cloudflare) and excludes `/health`
- WebSocket upgrades are forwarded transparently to the container for LiveView real-time updates
- Database migrations run automatically on each container start via `App.Release.migrate/0`
- Asset pipeline: esbuild + tailwind are Elixir-managed (no Node.js needed in the Docker build)
