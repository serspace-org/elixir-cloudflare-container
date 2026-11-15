# Setup and local development

## Prerequisites

- Cloudflare Workers **Paid** plan (required for Containers)
- GitHub repo secrets: `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`
- Elixir 1.15+ for local development (`mix.exs` requires `~> 1.15`; the Docker build uses 1.20)
- Node.js 22+ (the smoke-test script uses the built-in `WebSocket`)

## Cloudflare setup

### 1. Wrangler secrets

```bash
npx wrangler secret put SECRET_KEY_BASE   # output of: mix phx.gen.secret
npx wrangler secret put PHX_HOST           # e.g. phoenix-cf-container.serspace.dev
```

For local `wrangler dev`, mirror the same values into `.dev.vars` (gitignored).

### 2. Database (Cloudflare D1)

`wrangler.toml` already has a `[[d1_databases]]` block wired to the `DB` binding. Working from a fork means creating your own database and replacing `database_id`:

```bash
pnpm exec wrangler d1 create phoenix-cf-container-db
```

Then apply the migrations:

```bash
# Test against a local D1 first (optional):
pnpm exec wrangler d1 migrations apply phoenix-cf-container-db --local

# Apply to production:
pnpm exec wrangler d1 migrations apply phoenix-cf-container-db --remote
```

Until the binding is configured, the Worker skips the gateway entirely: `/tasks` shows a setup notice and `/chat` runs in ephemeral mode, so nothing else breaks.

### 3. Email sending (optional)

Skip this and the app works — registration and password login send no email at all. Without it, the magic-link and email-change flows stay hidden rather than failing; see [the mailer](authentication.md#mailer).

```bash
pnpm exec wrangler email sending enable mail.example.com      # a subdomain, not the root
pnpm exec wrangler email sending dns get mail.example.com     # verify SPF/DKIM/DMARC
pnpm exec wrangler email sending list                         # confirm it is onboarded
pnpm exec wrangler secret put MAIL_FROM                       # e.g. auth@mail.example.com
```

`enable` publishes the DNS records itself when the zone is on Cloudflare. **Use a subdomain, never the zone apex**: Email Sending puts the bounce MX on the domain you onboard, so onboarding the apex collides with whatever already receives mail there.

`MAIL_FROM` is the switch for the whole mail path, and it reaches Phoenix through `container.start()` — so **the container has to restart before it takes effect**. Setting a secret publishes a new Worker version but leaves the running container alone. Deploy, or leave the app idle for its inactivity timeout.

### 4. GitHub repo secrets

In your GitHub repo settings, add:

- `CLOUDFLARE_API_TOKEN` — a Cloudflare API token with Workers, Containers and D1 edit permissions (D1 because CI applies migrations before deploying)
- `CLOUDFLARE_ACCOUNT_ID` — your Cloudflare account ID

Optionally add a repo **variable** `SMOKE_URL` (the deployed hostname) to run the smoke test after each deploy. Without it, that CI step is skipped — which also means the form-redirect regression check in `scripts/ws-smoke.mjs` never runs, so setting it is worth the minute.

## Running it locally

Three local modes exist, and they are good at different things. Picking the wrong one costs an afternoon, so the [`justfile`](../justfile) names them and its header spells out the tradeoffs:

| Command | What runs | Database | Use it for |
| --- | --- | --- | --- |
| `just dev` | Phoenix natively | **Yes** — `App.D1.LocalGateway` on SQLite | app work; the fastest loop |
| `just worker-dev` | `wrangler dev`: the real Worker, DO and `d1.internal`/`mail.internal` intercepts | Yes — local D1 | anything in `src/index.ts`, because it is the only local mode that exercises the gateways |
| `just image-run` | the production release image | **No** | checking the image builds and boots — the thing that breaks on Apple Silicon |

`just --list` shows everything; `brew install just` if you do not have it.

### Native (no Docker)

```bash
just setup     # deps.get + assets.setup + assets.build
just dev       # http://localhost:4000
just iex       # the same, with an IEx shell attached
just test
```

`just setup` deliberately skips `mix setup`, which includes `ecto.setup` and wants Postgres on localhost. The app persists through D1, not Postgres, and `App.Repo` is only supervised when `DATABASE_URL` is set — so the Ecto step is vestigial. The equivalent by hand:

```bash
cd app
mix deps.get && mix assets.setup && mix assets.build
mix phx.server
```

### The production image

```bash
just image-build            # a few minutes; builds for your own architecture
just image-run              # http://localhost:4000
just image-health           # curl /health
```

Building for **your own** architecture is the point: it is the `linux/amd64` cross-build under QEMU that crashes the BEAM, so an arm64 build on an Apple Silicon Mac works fine and is a genuine check that the release compiles, the assets build, and the bcrypt NIF loads.

What it cannot do is use the database. The release compiles `http://d1.internal` in (`Application.compile_env`), and nothing serves that hostname outside a Worker, so `/health/sockets` reports `d1_ready: false`, `/tasks` shows a setup notice, `/chat` runs ephemeral, and **registering an account fails**. Every page still returns 200. For the full stack locally, use `just dev` or `just worker-dev`.

### How local persistence works

`mix phx.server` has real persistence. `App.D1.LocalGateway` (compiled in dev/test only) serves the same HTTP contract as the Worker's `D1Gateway` from a local SQLite file on port 4100, applying the very same `cloudflare/migrations/*.sql` on boot. D1 *is* SQLite, so the SQL and the migrations exercised locally are the real ones — a broken migration fails here first.

```bash
curl localhost:4000/health/sockets            # {"d1_ready":true, ...}
curl "localhost:4100/messages?room=lobby"     # the gateway itself, if you want to poke it
rm app/priv/d1_local.sqlite3                  # reset the local database
```

History survives a server restart, which is the thing worth checking: send a message, restart, reload, and it should still be there. Migrations are tracked in a `local_migrations` table, so a restart does not re-apply them.

It is **not** a substitute for `wrangler dev`: it covers the SQL, the migrations and the HTTP contract, but not the `d1.internal` outbound intercept or Cloudflare's D1. To run against the real gateway, point `:d1_url` back at `http://d1.internal` in `app/config/dev.exs`, drop the `:d1_local_gateway` config, and use:

```bash
pnpm exec wrangler d1 migrations apply phoenix-cf-container-db --local
pnpm exec wrangler dev
```

Because the local gateway binds port 4100, only one dev server can run at a time; a second one fails to boot on that port.

### Tests

```bash
cd app
mix test          # no Postgres needed
mix precommit     # compile --warnings-as-errors + deps.unlock --unused + format + test
```

D1 calls are stubbed with `Req.Test` through `App.D1Stub`, so the suite never reaches the network. `test/app/d1/local_gateway_test.exs` runs the repo's real migration files, which makes it a check on the migrations as well as the gateway.
