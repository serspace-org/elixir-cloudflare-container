# Elixir on Cloudflare Containers — PoC

A minimal Elixir application deployed as a Docker container on Cloudflare Containers.

## What's here

- **`app/`** — A minimal Elixir app using raw `:gen_tcp` (zero external dependencies) that serves two routes:
  - `GET /` — returns `{"ok": true, "message": "Hello from Elixir on Cloudflare Containers"}`
  - `GET /health` — returns `200 ok` (used by the Worker for readiness checks)
- **`src/index.ts`** — A Cloudflare Worker + Durable Object that manages the container lifecycle and proxies HTTP requests to it
- **`Dockerfile`** — Multi-stage build: compiles an Elixir release, then copies it into a minimal Alpine runtime image
- **`wrangler.toml`** — Wrangler config binding the container to a Durable Object

## Architecture

```
Client → Cloudflare Worker → Durable Object → Container (Elixir/:gen_tcp on :4000)
```

The Worker starts the container on first request, polls `/health` until it's ready, then forwards all requests to the Elixir app via TCP port 4000.

## Prerequisites

- Cloudflare Workers **Paid** plan
- [Docker](https://www.docker.com/) running locally (native AMD64, or QEMU emulation)
- Node.js (for Wrangler)

## Deploy

```bash
npm install
npx wrangler login
npx wrangler deploy
```

Wrangler builds the Docker image, pushes it to Cloudflare's registry, and deploys the Worker. First deploy takes a few minutes for image build + container provisioning.

## Test

```bash
curl https://elixir-cf-poc.<your-subdomain>.workers.dev/
# {"ok": true, "message": "Hello from Elixir on Cloudflare Containers"}

curl https://elixir-cf-poc.<your-subdomain>.workers.dev/health
# ok
```

First request may take 1-3s (cold start). Subsequent requests are instant while the container is warm.

## Notes

- Uses raw `:gen_tcp` instead of Plug/Bandit to avoid Elixir compiler bugs under QEMU emulation on Apple Silicon
- Disk is **ephemeral** — data is lost when the container sleeps
- No built-in autoscaling — the Worker routes to a named singleton instance
- Container sleeps after 2 minutes of inactivity (configurable via `INACTIVITY_TIMEOUT_MS`)
