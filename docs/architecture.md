# Architecture

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

In local development there is no Worker, so `App.D1.LocalGateway` serves the same HTTP contract from a local SQLite file. See [Running it locally](setup.md#running-it-locally).

## The gateway pattern

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

A fourth rule applies to any table a user owns: **the gateway filters by owner, in SQL, on every statement.** `tasks` and `rooms` are the two so far. Each task route takes a `user_id` and binds it alongside the id, so a task belonging to someone else answers 404 — the gateway is the only authorization boundary the container has, and a `WHERE` clause left off one statement is a cross-account leak. The Elixir side matches an `App.Accounts.Scope` rather than reading a user id out of it (`App.Tasks`), so a scope with no user raises instead of quietly listing everything.

Chat rooms apply the same rule with two twists (`App.Chat`, the room routes in `D1Gateway`):

- **A room with no row is a *link* room, open to anyone with the slug** — the behavior every room had before rooms became rows, which is why `lobby` and anonymously opened rooms need no row at all. A claimed room's row decides who may read and write (`owner`, a `room_memberships` row, or `visibility = 'link'`), and a row that denies the viewer answers **403, never an empty transcript** — collapsing 403 into 404 would make denial read as "unclaimed, come on in".
- **Anonymous callers are legitimate**, so `App.Chat` accepts a `nil` scope rather than matching one (the message paths send the viewer as JSON `null`, which the gateway reads as "absent", not "invalid"). Only room *management* — create, rename, share, revoke, delete — insists on a user.

The gateways have no automated tests against the real bindings — see [Known gaps](../README.md#known-gaps).

## What's in the repo

- **`app/`** — Phoenix 1.8.5 app (LiveView, Ecto, Bandit, Swoosh, Tailwind, esbuild)
  - `App.D1` — HTTP client for the Worker's private D1 gateway
  - `App.Tasks` — CRUD context over D1, scoped per user (`/tasks`)
  - `App.Chat` — chat context over D1, broadcast with `Phoenix.PubSub`; rooms can be owned, private and shared (`/chat/:room`, `/probe/:room`, `/rooms`)
  - `App.Accounts` — `mix phx.gen.auth` password authentication, moved off Ecto onto D1
  - `App.Mailer.Gateway` — Swoosh adapter that sends through the Worker's private mail gateway
  - `App.D1.LocalGateway` — dev/test stand-in for the Worker's D1 gateway, backed by local SQLite
  - `app/AGENTS.md` — Phoenix/Elixir/LiveView coding rules for everything under `app/`
- **`src/index.ts`** — Worker + Durable Object: container lifecycle, HTTP/WebSocket proxying, and the `D1Gateway` and `MailGateway` entrypoints
- **`docs/troubleshooting.md`** — how to see what the Worker, container, database and mailer are actually doing, plus a log of the bugs this setup has already produced
- **`cloudflare/migrations/`** — SQL migrations applied to D1 with Wrangler
- **`Dockerfile`** — Multi-stage build: compiles an Elixir release with assets, copies into minimal Alpine runtime
- **`wrangler.toml`** — Wrangler config (container, Durable Object, D1 and Email Sending bindings)
- **`justfile`** — the everyday local commands, and the header explaining which of the three local modes to use (`just dev`, `just worker-dev`, `just image-run`)
- **`scripts/ws-smoke.mjs`** — post-deploy WebSocket/channel smoke test (`pnpm ws:smoke <url>`)
- **`.github/workflows/deploy.yml`** — CI workflow that deploys on push to `main`

## Operational facts

- Container instance type is `basic` (1/4 vCPU, 1 GiB RAM, 4 GB disk), with internet access enabled. It is set in `container.start()` in `src/index.ts`, **not** `instance_type` in `wrangler.toml` — with `scheduling_policy = "durable_object"` the Durable Object picks the image and size at every start, and omitting it would silently get `lite` (256 MiB), which is not enough for the BEAM plus a bcrypt hash
- Password hashing is bcrypt (Phoenix's default on Unix). The NIF compiles in the existing Alpine build stage; argon2 would be stronger but its default ~128 MB per hash is a poor fit for a `basic` instance
- Container sleeps after 10 minutes of inactivity (configurable via `INACTIVITY_TIMEOUT_MS` in `src/index.ts`); every request renews the deadline
- Readiness: the DO polls `GET /health` every 300 ms for up to 100 attempts (~30s) before giving up
- A proxy failure — a fetch that throws, or a container that never becomes ready — answers **503 with `retry-after: 5`** and logs the exception, rather than letting the throw surface as Cloudflare error 1101
- Disk is **ephemeral** — durable state lives in D1
- The Worker handles TLS; the container serves plain HTTP behind it
- `force_ssl` uses `x-forwarded-proto` and excludes `/health`
- WebSocket upgrades are forwarded transparently to the container, for both LiveView and plain channels
- Every request is routed to a single Durable Object (`getByName("singleton")`), so all sockets share one BEAM node and local `Phoenix.PubSub` is sufficient — sharding the DO would split chat and presence per instance
- Asset pipeline: esbuild + tailwind are Elixir-managed (no Node.js needed in the Docker build)
- `pnpm` is the package manager for local work; CI uses `npm install` (both lockfiles are committed)
