# Phoenix on Cloudflare Containers

A full Phoenix 1.8 LiveView application deployed as a Docker container on Cloudflare Containers, with a Cloudflare Worker + Durable Object as the proxy layer — including WebSocket support for both LiveView and plain Phoenix Channels.

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

In local development there is no Worker, so `App.D1.LocalGateway` serves the same HTTP contract from a local SQLite file. See [Local development](#local-development).

## What's here

- **`app/`** — Phoenix 1.8.5 app (LiveView, Ecto, Bandit, Swoosh, Tailwind, esbuild)
  - `App.D1` — HTTP client for the Worker's private D1 gateway
  - `App.Tasks` — CRUD context over D1 (`/tasks`)
  - `App.Chat` — chat context over D1, broadcast with `Phoenix.PubSub` (`/chat/:room`, `/probe/:room`)
  - `App.Accounts` — `mix phx.gen.auth` password authentication, moved off Ecto onto D1
  - `App.D1.LocalGateway` — dev/test stand-in for the Worker's D1 gateway, backed by local SQLite
  - `app/AGENTS.md` — Phoenix/Elixir/LiveView coding rules for everything under `app/`
- **`src/index.ts`** — Worker + Durable Object: container lifecycle, HTTP/WebSocket proxying, and the `D1Gateway` entrypoint
- **`cloudflare/migrations/`** — SQL migrations applied to D1 with Wrangler
- **`Dockerfile`** — Multi-stage build: compiles an Elixir release with assets, copies into minimal Alpine runtime
- **`wrangler.toml`** — Wrangler config (container, Durable Object, D1 binding)
- **`scripts/ws-smoke.mjs`** — post-deploy WebSocket/channel smoke test (`pnpm ws:smoke <url>`)
- **`.github/workflows/deploy.yml`** — CI workflow that deploys on push to `main`

## Routes

| Route | What it is |
| --- | --- |
| `/` | stock Phoenix landing page |
| `/users/register` | register with an email and a password |
| `/users/log-in` | log in with a password (or request a magic link, once a mailer is wired) |
| `/users/log-out` | log out (`DELETE`) |
| `/users/settings` | change email and password; requires sudo mode |
| `/tasks` | D1-backed CRUD demo (LiveView) |
| `/chat`, `/chat/:room` | chat demo on LiveView's `/live` socket |
| `/probe`, `/probe/:room` | same chat room over a raw `Phoenix.Channel` on `/socket` |
| `/health` | readiness probe used by the Durable Object — unauthenticated, never redirects |
| `/health/sockets` | socket/node diagnostics as JSON; takes an optional `?room=` |

## Prerequisites

- Cloudflare Workers **Paid** plan (required for Containers)
- GitHub repo secrets: `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`
- Elixir 1.15+ for local development (`mix.exs` requires `~> 1.15`; the Docker build uses 1.20)
- Node.js 22+ (the smoke-test script uses the built-in `WebSocket`)

## Setup

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

### 3. GitHub repo secrets

In your GitHub repo settings, add:

- `CLOUDFLARE_API_TOKEN` — a Cloudflare API token with Workers, Containers and D1 edit permissions (D1 because CI applies migrations before deploying)
- `CLOUDFLARE_ACCOUNT_ID` — your Cloudflare account ID

Optionally add a repo **variable** `SMOKE_URL` (the deployed hostname) to run the WebSocket smoke test after each deploy. Without it, that CI step is skipped.

## Local development

Run the Phoenix app directly for everything except the Worker itself:

```bash
cd app
mix setup          # NOTE: includes ecto.setup, which needs Postgres on localhost
mix phx.server     # http://localhost:4000
```

The app persists through D1, not Postgres, so `App.Repo` is only supervised when `DATABASE_URL` is set. If you don't have Postgres, skip the vestigial Ecto step:

```bash
mix deps.get && mix assets.setup && mix assets.build
mix phx.server
```

### Local persistence (no Docker)

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

## Deploy

### Via CI (recommended)

Push to the `main` branch. GitHub Actions applies any pending D1 migrations, then builds the Docker image on native AMD64 (`ubuntu-latest`), pushes it to Cloudflare's registry, and deploys the Worker. The first deploy takes 5–10 minutes for the image build. If the `SMOKE_URL` repo variable is set, the WebSocket smoke test runs against the deployment afterwards and fails the build if the socket is broken.

Migrations run **before** the deploy on purpose, so code can never ship ahead of its schema. If a migration fails, the deploy never happens. This means `CLOUDFLARE_API_TOKEN` needs D1 edit permission alongside Workers and Containers.

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

CI applies pending migrations before each deploy (see `.github/workflows/deploy.yml`), so pushing a migration and the code that needs it in the same commit is safe. Run the `--remote` command by hand only when you need the schema live ahead of a deploy. Wrangler records applied migrations in D1's `d1_migrations` table and the command is idempotent, so re-running it is harmless.

**Keep migrations additive** (new tables and columns) while the previous version is still serving traffic: the old code keeps running for the length of the deploy, and the new schema has to be compatible with it. This is the same constraint any migrate-then-deploy pipeline has.

A new table or endpoint touches four places, which have to stay in step: the migration, a route in `D1Gateway` (`src/index.ts`), a client function in `app/lib/app/d1.ex`, and the same route in `App.D1.LocalGateway.Router`. The `tasks`, `messages`, `users` and `users_tokens` tables are all wired this way — copy any of them. Keep all SQL parameterized (`?1`-style binds).

Note: D1 is not an Ecto repo. `App.Tasks`, `App.Chat` and `App.Accounts` validate with embedded schemas and persist through `App.D1`; `mix ecto.*` tasks do not apply.

## Authentication

Generated with `mix phx.gen.auth Accounts User users --live --hashing-lib bcrypt`, then adapted to this app's data layer. You get the generator's full scope-based stack — `AppWeb.UserAuth` (plug + `on_mount`), session tokens in the database, remember-me cookie, sudo mode, and the `@current_scope` assign — with Cloudflare D1 underneath instead of Postgres.

Register at `/users/register` with an email and a password and you are logged in immediately. **No email is sent**, by design for now: see [Mailer](#mailer-not-wired-yet).

### What changed from the generated code, and why

| Generated | Here |
| --- | --- |
| `Repo.*` in `App.Accounts` | calls to the private D1 gateway through `App.D1` |
| `UserToken.verify_*_query/1` (`Ecto.Query`) | fetch by `{context, token}`, then a `*_valid?/1` check from `App.Accounts.UserToken` |
| `Repo.transact/1` around update-and-expire-tokens | one D1 `batch`, which is a single implicit transaction (`PATCH /users/:id`) |
| `unsafe_validate_unique(:email, App.Repo)` | a read through the gateway; the unique index on `lower(users.email)` still decides, and its 409 becomes a changeset error |
| `citext` email column | `TEXT` plus a unique index on `lower(email)`; lookups bind `lower(?1)` |
| `bytea` token column, `utc_datetime` timestamps | lowercase hex, and `TEXT` in SQLite's `CURRENT_TIMESTAMP` format |
| Register by email, first login by magic link | register with email **and** password, logged in straight away, no email sent |

Registration taking a password is the one change with a security consequence, and `mix help phx.gen.auth` spells it out: an attacker can register a victim's address, set a password, and keep access after the victim later confirms by magic link. The prescribed mitigation is implemented — `App.Accounts.login_user_by_magic_link/2` takes the current user and refuses to confirm an unconfirmed, password-holding account unless the requester is already logged in as that user. `AppWeb.UserLive.Confirmation` says so rather than offering a button that would fail.

Accounts therefore stay **unconfirmed** until a mailer exists; nothing in the app gates on `confirmed_at` yet.

### Mailer (not wired yet)

`App.Accounts.UserNotifier` is the generated Swoosh notifier and works in dev — `mix phx.server` then `/dev/mailbox`. In production no adapter is configured, so magic links, email-change confirmations and (once written) password resets go nowhere.

Cloudflare's own Email Service is the natural fit, and it needs no custom Swoosh adapter — it speaks SMTP submission:

```elixir
# config/runtime.exs, under `if config_env() == :prod do`
config :app, App.Mailer,
  adapter: Swoosh.Adapters.SMTP,
  relay: "smtp.mx.cloudflare.net",
  port: 465,
  ssl: true,
  username: "api_token",
  password: System.fetch_env!("CLOUDFLARE_EMAIL_API_TOKEN"),
  auth: :always
```

That needs `{:gen_smtp, "~> 1.2"}` in `mix.exs` (Swoosh's SMTP adapter dependency), the token as a Worker secret passed into the container, and the sending domain onboarded with `wrangler email sending enable <domain>`. Two constraints to know before committing to it:

- Until a sending domain is onboarded you can only send to **verified destination addresses** in the account, which is useless for real signups. After onboarding, any recipient works.
- Arbitrary recipients need the **Workers Paid** plan: 3,000 emails/month included, then $0.35 per 1,000. Sends to verified destinations are always free and don't count against the quota.

There is also a REST endpoint (`POST /accounts/{account_id}/email/sending/send`) and a Worker `send_email` binding. The binding is the only option that keeps an API token out of the image entirely — it would ride the same `interceptOutboundHttp` trick as `D1Gateway`, as a `MailGateway` on a `mail.internal` hostname. SMTP is less code; the binding is tighter. Either way, the work left after that is a password-reset flow, which is what lets a victim of the pre-stuffing attack above recover their account.

## Chat (WebSocket + Channels) demo

### Sessions and sharing

Both chat clients are room-scoped, so a session is just a URL you can hand to someone:

| URL | What it is |
| --- | --- |
| `/chat` | LiveView client in the default `lobby` room |
| `/chat/:room` | LiveView client in a named room |
| `/probe/:room` | raw-channel client in the same room |

**New session** on `/chat` generates a fresh room slug and navigates to it; the share box next to it holds the link to send. Rooms are isolated — messages, history and presence are all per-room. Room names are validated against `^[a-z0-9][a-z0-9-]{0,63}$` (`App.Chat.valid_room?/1`) because the name reaches both a channel topic and the database; anything else falls back to `lobby`. `?as=<name>` sets your display name, and the **Rename** field changes it live.

To share a local session with someone on your network, note that dev is bound to loopback — change `http: [ip: {127, 0, 0, 1}]` to `ip: {0, 0, 0, 0}` in `app/config/dev.exs` and give them `http://<your-lan-ip>:4000/chat/<room>`. `check_origin` is already disabled in dev.

### Two sockets, verified separately

Phoenix's two socket paths are verified separately, because they fail differently:

| Route | Socket | What a failure tells you |
| --- | --- | --- |
| `/chat/:room` | LiveView on `/live` | LiveView real-time updates |
| `/probe/:room` | raw `Phoenix.Channel` on `/socket`, **no long-poll fallback** | the WebSocket upgrade itself |

The reason for two is that `assets/js/app.js` sets `longPollFallbackMs`, so a broken WebSocket upgrade makes LiveView quietly fall back to long-polling and *everything still looks fine*. `/socket` sets `longpoll: false`, and both pages print the transport actually in use, so a degraded connection is visible rather than invisible.

### What to check

```bash
pnpm ws:smoke https://<your-host>   # scripted: handshake, join, broadcast round trip
SMOKE_ROOM=standup pnpm ws:smoke https://<your-host>   # in a specific room

curl https://<your-host>/health/sockets        # add ?room=<room> for a specific room
# {"status":"ok","node":"...","node_uptime_ms":123456,"present":0,"d1_ready":true,...}
```

By hand, open `/chat/<room>` and `/probe/<room>` side by side (or share the link and have someone join from their own machine):

1. **Transport** on both pages must say `websocket`. `/chat` turns the card red and says so explicitly if the LiveView socket degraded to long-polling.
2. **Cross-socket fan-out** — a message sent in `/probe` must appear in `/chat` and vice versa. That exercises `Phoenix.PubSub` between two different socket implementations.
3. **Presence** — *Online now* must rise and fall as you open and close tabs.
4. **Round trip** on `/probe` is the real latency through Worker → Durable Object → container.
5. **Node uptime** is the one to watch on a reconnect: if it *keeps climbing*, only the socket reconnected; if it *resets to zero*, the container cold-started and you lost BEAM state. Persisted history survives either way, which is the point of storing it in D1.
6. **Idle survival** — leave a tab open and idle for more than 10 minutes (the Durable Object's `INACTIVITY_TIMEOUT_MS`). Phoenix heartbeats every 30s, so the socket should stay up and node uptime should keep climbing. If it does not, WebSocket traffic is not counting as container activity and the timeout needs raising or a keepalive adding.

When the D1 gateway is unreachable — no `DB` binding, or the local gateway disabled — chat still works but marks itself *ephemeral* and keeps no history, so the transport can be tested on its own.

## Verifying a deployment

```bash
curl https://<your-host>/
curl https://<your-host>/health
# ok
```

Then open `/tasks` for the D1-backed CRUD demo and `/chat` for the WebSocket demo.

The first request may take 5–15 seconds (container cold start). Subsequent requests are instant while the container is warm.

## Notes

- Container instance type is `basic` (1 GiB RAM)
- Password hashing is bcrypt (Phoenix's default on Unix). The NIF compiles in the existing Alpine build stage; argon2 would be stronger but its default ~128 MB per hash is a poor fit for a `basic` instance
- Container sleeps after 10 minutes of inactivity (configurable via `INACTIVITY_TIMEOUT_MS` in `src/index.ts`)
- Disk is **ephemeral** — durable state lives in D1
- The Worker handles TLS; the container serves plain HTTP behind it
- `force_ssl` uses `x-forwarded-proto` and excludes `/health`
- WebSocket upgrades are forwarded transparently to the container, for both LiveView and plain channels
- Every request is routed to a single Durable Object (`getByName("singleton")`), so all sockets share one BEAM node and local `Phoenix.PubSub` is sufficient — sharding the DO would split chat and presence per instance
- Asset pipeline: esbuild + tailwind are Elixir-managed (no Node.js needed in the Docker build)
- `pnpm` is the package manager for local work; CI uses `npm install` (both lockfiles are committed)
