# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Phoenix 1.8 LiveView app packaged as a Docker container and served on Cloudflare Containers, fronted by a Worker + Durable Object. See `README.md` for setup/deploy prose; `app/AGENTS.md` holds the Phoenix/Elixir/LiveView coding rules and applies to everything under `app/` — read it before touching Elixir or HEEx.

## Architecture

```
Client (HTTPS) → Worker (src/index.ts) → ElixirContainer (Durable Object) → container, Phoenix on :4000
                                                                                  ↓ http://d1.internal
                                                              D1Gateway (WorkerEntrypoint) → D1 binding `DB`
```

Three pieces that only make sense together:

1. **`src/index.ts` — Worker + `ElixirContainer` Durable Object.** The default fetch routes *every* request to a single DO instance (`getByName("singleton")`). The DO starts the container on first request, polls `GET /health` until 200 (up to ~30s), sets a 10-minute inactivity timeout, then proxies HTTP and WebSocket traffic verbatim to port 4000, injecting `x-forwarded-proto: https`. Container env (`SECRET_KEY_BASE`, `PHX_HOST`, `PORT`) is passed at `container.start()` from Worker secrets — the image carries no config.

2. **`D1Gateway` (also `src/index.ts`) — the database path.** Before starting the container, the DO registers `container.interceptOutboundHttp("d1.internal", ctx.exports.D1Gateway(...))`. Phoenix then talks to D1 by making plain HTTP calls to `http://d1.internal/tasks...` (`App.D1`, using `Req`). Nothing is exposed publicly and no DB credentials exist in the image. This requires `compatibility_flags = ["enable_ctx_exports"]` in `wrangler.toml`, and the gateway is only registered when `env.DB` exists.

   **Adding a table/endpoint means editing three places in lockstep**: a SQL migration in `cloudflare/migrations/`, a route + parameterized query in `D1Gateway`, and a client function in `app/lib/app/d1.ex`. Keep all SQL parameterized (`?1`-style binds).

3. **D1 is not an Ecto repo.** `App.Tasks.Task` is an `embedded_schema` used purely for casting/validation; `App.Tasks` applies the changeset with `Changeset.apply_action/2` and persists via `App.D1`. `mix ecto.gen.migration` / `mix ecto.migrate` do **not** apply to D1 data. `App.Repo` (Postgres) and `App.Release.migrate` are vestigial — both are no-ops unless `DATABASE_URL` is set (see `App.Application.start/2`, which only supervises `App.Repo` when that env var exists).

## Commands

Elixir (run from `app/`):

```bash
mix setup                      # deps + assets (ecto.setup needs local Postgres)
mix phx.server                 # dev server on :4000
mix test                       # NOTE: the `test` alias runs ecto.create/ecto.migrate,
                               # so it needs Postgres on localhost even though the app uses D1
mix test test/path_test.exs:42 # single test
mix test --failed
mix precommit                  # compile --warnings-as-errors + deps.unlock --unused + format + test
mix format
```

Worker / Cloudflare (run from the repo root; `pnpm` is the package manager):

```bash
pnpm exec wrangler dev                                                  # local Worker (reads .dev.vars)
pnpm exec wrangler deploy                                               # see caveat below
pnpm exec wrangler d1 migrations create phoenix-cf-container-db <name>
pnpm exec wrangler d1 migrations apply phoenix-cf-container-db --local
pnpm exec wrangler d1 migrations apply phoenix-cf-container-db --remote
pnpm exec wrangler tail                                                 # Worker logs
```

**Deploy from CI, not locally, on Apple Silicon.** `wrangler deploy` cross-builds the `linux/amd64` image under QEMU and the BEAM crashes during dependency compilation. Pushing to `main` runs `.github/workflows/deploy.yml` on native AMD64 `ubuntu-latest`. The `ERL_FLAGS="+JMsingle true"` lines in both Dockerfile stages are a workaround for this same QEMU bug — don't remove them.

Apply D1 migrations **before** deploying code that depends on them, and keep them additive while the previous version is still serving traffic.

## Gotchas

- `/health` must stay unauthenticated, fast, and excluded from `force_ssl` (`config/prod.exs`) — the DO's readiness poll depends on it, and the container never becomes ready if it redirects.
- Container disk is ephemeral. Durable state belongs in D1.
- Assets are Elixir-managed (`esbuild`/`tailwind` Hex packages); there is no Node.js in the Docker build and no `assets/package.json`. Tailwind v4, no `tailwind.config.js`.
- Secrets (`SECRET_KEY_BASE`, `PHX_HOST`) are Worker secrets set with `wrangler secret put`, mirrored into `.dev.vars` for local dev.
