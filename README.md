# Phoenix on Cloudflare Containers

A full Phoenix 1.8 LiveView application deployed as a Docker container on Cloudflare Containers, with a Cloudflare Worker + Durable Object as the proxy layer — including WebSocket support for both LiveView and plain Phoenix Channels.

This repo is a work in progress.

## Architecture

```
Client (HTTPS) → Cloudflare Worker → Durable Object → Container (Phoenix on :4000)
                                                               │
                        ┌──────────────────────────────────────┴───────────┐
                        │ outbound HTTP intercepts (container-only DNS)    │
                        ↓                                                 ↓
            http://d1.internal                                http://mail.internal
            D1Gateway (WorkerEntrypoint)                      MailGateway (WorkerEntrypoint)
                        ↓                                                 ↓
            Cloudflare D1 (`DB` binding)                 Email Sending (`EMAIL` binding)
```

The Worker starts the container on first request, polls `/health` until it's ready, then proxies all HTTP and WebSocket traffic to the Phoenix app on port 4000.

Everything the container needs from Cloudflare arrives through a **private gateway** rather than a credential. Phoenix makes plain HTTP calls to a hostname that resolves only inside the container, the Worker intercepts it, and a `WorkerEntrypoint` serves it using a binding. Nothing is exposed publicly and **no API tokens or database credentials ship in the image**. See [The gateway pattern](#the-gateway-pattern).

In local development there is no Worker, so `App.D1.LocalGateway` serves the same HTTP contract from a local SQLite file. See [Local development](#local-development).

### The gateway pattern

Two gateways exist today and both follow the same shape, so a third should too:

| Gateway | Hostname | Binding | Elixir client |
| --- | --- | --- | --- |
| `D1Gateway` | `d1.internal` | `DB` (D1) | `App.D1` |
| `MailGateway` | `mail.internal` | `EMAIL` (Email Sending) | `App.Mailer.Gateway` |

Both are registered with `container.interceptOutboundHttp(...)` in `ElixirContainer.startAndWait()` before the container starts, and both are only registered when their binding is configured — so a missing binding degrades a feature rather than breaking the app.

Three rules, each of which was learned by shipping a bug:

1. **A new route touches four places in lockstep** — the SQL migration, the route in the Worker gateway, the client function in Elixir, and the same route in `App.D1.LocalGateway.Router` (the dev/test stand-in). Drift between the Worker gateway and the local one makes local runs lie about production.
2. **JSON has no `undefined`, so `null` means "absent".** Elixir sends `null` for a field it has no value for. A gateway reader that treats `null` as *invalid* rejects real messages; use the `readOptional*` helpers. D1 goes further and **throws** on `undefined` in `bind()`, so nullable columns need `bindable()`.
3. **Never return a rejection without logging it.** A 400 from a gateway is a normal `Response`, so the Worker invocation still reports `outcome: ok` — in `wrangler tail` that is indistinguishable from success. Every rejection path names what was wrong, and every successful send logs its message id.

The gateways have no automated tests against the real bindings — see [Known gaps](#known-gaps).

## What's here

- **`app/`** — Phoenix 1.8.5 app (LiveView, Ecto, Bandit, Swoosh, Tailwind, esbuild)
  - `App.D1` — HTTP client for the Worker's private D1 gateway
  - `App.Tasks` — CRUD context over D1 (`/tasks`)
  - `App.Chat` — chat context over D1, broadcast with `Phoenix.PubSub` (`/chat/:room`, `/probe/:room`)
  - `App.Accounts` — `mix phx.gen.auth` password authentication, moved off Ecto onto D1
  - `App.Mailer.Gateway` — Swoosh adapter that sends through the Worker's private mail gateway
  - `App.D1.LocalGateway` — dev/test stand-in for the Worker's D1 gateway, backed by local SQLite
  - `app/AGENTS.md` — Phoenix/Elixir/LiveView coding rules for everything under `app/`
- **`src/index.ts`** — Worker + Durable Object: container lifecycle, HTTP/WebSocket proxying, and the `D1Gateway` and `MailGateway` entrypoints
- **`docs/troubleshooting.md`** — how to see what the Worker, container, database and mailer are actually doing, plus a log of the bugs this setup has already produced
- **`cloudflare/migrations/`** — SQL migrations applied to D1 with Wrangler
- **`Dockerfile`** — Multi-stage build: compiles an Elixir release with assets, copies into minimal Alpine runtime
- **`wrangler.toml`** — Wrangler config (container, Durable Object, D1 and Email Sending bindings)
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

### 3. Email sending (optional)

Skip this and the app works — registration and password login send no email at all. Without it, the magic-link and email-change flows stay hidden rather than failing; see [Mailer](#mailer).

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

### How a deploy actually reaches users

Worker code goes live the moment `wrangler deploy` finishes, but the **container does not**: the Durable Object skips `start()` whenever one is already running, and the only thing that stops it is the inactivity timeout — which every single request pushes another 10 minutes out. Left alone, a deploy on a site with steady traffic may never take effect, and nothing looks wrong: the deploy is green, the old image keeps answering, and routes added in that deploy return 404.

So the DO records the image it started in its own storage and compares it on each request (`rollStaleContainer` in `src/index.ts`). When a deploy changes the image, the first request afterwards stops the old container so the next start picks up the new one. The cost is one cold start (5–15s) on that request, and in-flight WebSockets are dropped — LiveView reconnects on its own, and a deploy is the one moment that is worth it.

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

### Confirming an account

Registration leaves `confirmed_at` empty, and nothing in the app gates on it — so this only matters when you want magic-link login to work.

The order is not guessable, which is a usability problem rather than a bug:

1. `/users/log-in` → "Log in with email" sends an email titled **"Confirmation instructions"**, not a login link, because the account is unconfirmed (`UserNotifier.deliver_login_instructions/2` branches on it).
2. Opening that link **while logged out is refused** — "Please log in with your password to confirm your account." The account has a password and is unconfirmed, which is exactly the credential pre-stuffing case the mitigation blocks.
3. Log in with the password first, then open the link in the same browser, and it confirms the account.
4. From then on "Log in with email" sends a real magic link that works on its own.

The clean fix is an "unconfirmed — confirm your email" banner with a resend button shown after password login, so confirmation happens on the natural path while the user is already authenticated. Not implemented; see [Known gaps](#known-gaps).

### Mailer

Account email goes through a **private mail gateway in the Worker**, the same arrangement the database uses: the container POSTs to `http://mail.internal/send`, a hostname that resolves only inside it, and `MailGateway` (`src/index.ts`) does the sending with Cloudflare Email Service via the Worker's `EMAIL` binding.

The point is that **no API token exists in the container image**. An Email Sending token is account-wide — it can send from every onboarded domain you have — so putting one in the container environment would mean that code execution anywhere in the Elixir app, including in a dependency, becomes the ability to send mail as your domain. Here the capability stays in the Worker isolate and the container only gets to ask.

Asking is still a capability, so the gateway narrows it: the sender is pinned to `MAIL_FROM` and whatever the caller sends for `from` is ignored, there is exactly one recipient per request, and cc, bcc, attachments and custom headers are refused outright. `App.Mailer.Gateway` refuses the same things on the Elixir side rather than dropping them silently, because an account email that half-arrives is worse than one that visibly fails.

Sending from the Worker also keeps it off the critical path: every request to this app funnels through one Durable Object and one `basic` container, and an SMTP handshake per message would block a LiveView process on the one fractional vCPU everything else shares.

#### Turning it on

```bash
pnpm exec wrangler email sending enable mail.example.com      # a subdomain, not the root
pnpm exec wrangler email sending dns get mail.example.com     # check the SPF/DKIM/DMARC records
pnpm exec wrangler email sending list                         # confirm it is onboarded
pnpm exec wrangler secret put MAIL_FROM                       # e.g. auth@mail.example.com
```

Prove the domain works before involving the app, so a failure has one possible cause rather than two:

```bash
pnpm exec wrangler email sending send \
  --from auth@mail.example.com --to you@example.com \
  --subject "Email Sending check" --text "hello"
```

`MAIL_FROM` reaches Phoenix through `container.start()`, so **the container has to restart before it sees it**. Setting the secret publishes a new Worker version but leaves the running container alone, and `rollStaleContainer` only reacts to a changed image. Either leave the app idle for its 10-minute inactivity timeout, or push any commit to trigger a deploy.

A subdomain rather than the root domain keeps this app's sending reputation separate from your main mail. Note that **until a sending domain is onboarded you can only send to verified destination addresses** in the account, which is no use for real signups; after onboarding, any recipient works. Arbitrary recipients need Workers Paid (which Containers already requires): 3,000 messages a month included, then $0.35 per 1,000. Sends to verified destinations are always free.

`MAIL_FROM` is the switch for the whole path. Until it is set, the binding goes unused, the `mail.internal` intercept is never registered, `App.Mailer` stays on the Local adapter, and `App.Accounts.email_delivery_available?/0` keeps the mail-dependent flows hidden. Setting it reverses all of that with no code change — the magic-link form returns to `/users/log-in` and the email-change form to `/users/settings`.

Once the domain is onboarded, pin the sender at the platform level too by adding `allowed_sender_addresses = ["auth@mail.example.com"]` to the `[[send_email]]` binding in `wrangler.toml`. That moves the sender restriction out of gateway code and into Cloudflare's enforcement.

Development keeps `Swoosh.Adapters.Local` and the `/dev/mailbox` preview — better to work with, and the only option without a Worker.

Email Sending is in **open beta**. Treat delivery as best-effort: password login stays the primary path, which is why registration does not depend on email at all.

Every send is logged by the gateway, so delivery questions are answerable from `wrangler tail`:

```
MailGateway sent <abc…@mail.example.com> to *@example.com
MailGateway rejected a message, invalid: replyTo
MailGateway cannot send, missing: MAIL_FROM
```

The message id is the key into Cloudflare's own records. The recipient's *domain* is logged but not the address — user addresses do not belong in Worker logs.

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

## Troubleshooting

[`docs/troubleshooting.md`](docs/troubleshooting.md) is the runbook: how to read the Worker's logs, confirm a deploy actually reached users, inspect D1 and the mail queue directly, and drive a LiveView over a raw socket when you need to reproduce something without a browser. It also logs the bugs this setup has already produced and what each one taught, because every one of them looked like something else first.

The three checks that answer most questions:

```bash
pnpm exec wrangler tail phoenix-cf-container --format json   # what the Worker is doing, live
curl -s https://<host>/health/sockets                        # node, uptime, d1_ready
pnpm exec wrangler d1 execute DB --remote --json \
  --command "SELECT id, email, confirmed_at FROM users"      # what is actually stored
```

A container's `node_uptime_ms` older than your last deploy means the old image is still serving — see [How a deploy actually reaches users](#how-a-deploy-actually-reaches-users).

## Known gaps

Honest list, so nobody mistakes this for finished:

- **The Worker's gateways have no tests against the real bindings.** `D1Gateway` and `MailGateway` are only exercised through Elixir, against a `Req.Test` stub or the local SQLite stand-in, neither of which can see the Worker's code. Two production defects came from exactly that blind spot (both in the log in `docs/troubleshooting.md`). A Miniflare harness is the missing piece.
- **No password reset.** It is what lets someone recover when an attacker registered their address first and set a password — the credential pre-stuffing case the registration design obliges us to cover. Needs the mailer, which now exists.
- **No "confirm your email" prompt**, so the confirmation order above has to be known rather than discovered.
- **Email Sending is in open beta.** Treat delivery as best-effort; password login is deliberately the primary path.
- **A deploy costs one cold start and drops open WebSockets.** The container is replaced rather than drained, because a Durable Object has exactly one container and cannot run both.
- **`package-lock.json` is a stub** while `deploy.yml` installs with `npm install`, so production installs are not pinned. The CI workflow uses pnpm with `--frozen-lockfile`.

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
