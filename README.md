# Phoenix on Cloudflare Containers

A full Phoenix 1.8 LiveView application deployed as a Docker container on Cloudflare Containers, with a Cloudflare Worker + Durable Object as the proxy layer — including WebSocket support for both LiveView and plain Phoenix Channels, a D1-backed database, password authentication, and transactional email.

This repo is a work in progress.

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

Everything the container needs from Cloudflare arrives through a **private gateway** rather than a credential: Phoenix makes plain HTTP calls to a hostname that resolves only inside the container, the Worker intercepts it, and a `WorkerEntrypoint` serves it using a binding. Nothing is exposed publicly and **no API tokens or database credentials ship in the image**.

## Documentation

| Document | What's in it |
| --- | --- |
| [Architecture](docs/architecture.md) | The gateway pattern and its rules, what's in the repo, operational facts |
| [Setup and local development](docs/setup.md) | Secrets, D1, email sending, running and testing without Docker |
| [Deploying](docs/deploy.md) | CI, how a deploy actually reaches users, D1 migrations |
| [Authentication](docs/authentication.md) | `phx.gen.auth` ported off Ecto, the confirmation flow, the mailer |
| [WebSockets and channels](docs/realtime.md) | Two socket paths, the chat demo, what to verify |
| [Troubleshooting](docs/troubleshooting.md) | Reading the Worker's logs, inspecting D1 and mail — and a log of the bugs this setup has already produced |

`app/AGENTS.md` holds the Phoenix/Elixir/LiveView coding rules for everything under `app/`; `CLAUDE.md` is the short orientation for agents.

## Routes

| Route | What it is |
| --- | --- |
| `/` | stock Phoenix landing page |
| `/users/register` | register with an email and a password |
| `/users/log-in` | log in with a password, or request a magic link when a mailer is configured |
| `/users/log-in/:token` | magic-link / confirmation link; see [the confirmation order](docs/authentication.md#confirming-an-account) |
| `/users/log-out` | log out (`DELETE`) |
| `/users/settings` | change email and password; requires sudo mode |
| `/tasks` | D1-backed CRUD demo (LiveView); requires a logged-in user, and each user sees only their own tasks |
| `/chat`, `/chat/:room` | chat demo on LiveView's `/live` socket |
| `/probe`, `/probe/:room` | same chat room over a raw `Phoenix.Channel` on `/socket` |
| `/health` | readiness probe used by the Durable Object — unauthenticated, never redirects |
| `/health/sockets` | socket/node diagnostics as JSON; takes an optional `?room=` |
| `/dev/dashboard`, `/dev/mailbox` | LiveDashboard and the Swoosh mailbox preview — **dev only** (`:dev_routes`) |

## Quick start

Needs a Cloudflare Workers **Paid** plan (Containers requires it), Elixir 1.15+ and Node 22+.

Everyday commands live in the [`justfile`](justfile) — `just` on its own lists them:

```bash
brew install just     # if you do not have it
just setup            # deps and assets (skips the Postgres-only ecto.setup)
just dev              # http://localhost:4000, with a real local database
just test
```

`just dev` runs Phoenix natively with full features: `App.D1.LocalGateway` serves the Worker's D1 contract from SQLite, so persistence, tasks, chat history and accounts all work. Two other local modes exist and are good at different things — `just worker-dev` for the real Worker and its gateway intercepts, `just image-build && just image-run` for the production image on its own. The tradeoffs are in the justfile header and in [Setup](docs/setup.md#running-it-locally).

To deploy, push to `main`: CI applies pending D1 migrations, builds the image on native AMD64, and deploys the Worker. **Deploy from CI rather than locally on Apple Silicon** — the `linux/amd64` cross-build crashes the BEAM under QEMU.

Full instructions: [Setup](docs/setup.md), then [Deploying](docs/deploy.md).

## Known gaps

So nobody mistakes this for finished:

- **The Worker's gateways have no tests against the real bindings.** `D1Gateway` and `MailGateway` are only exercised through Elixir — a `Req.Test` stub, or the local SQLite stand-in — neither of which can see the Worker's code. Two production defects came from that blind spot; a Miniflare harness is the missing piece.
- **No password reset**, which is what lets someone recover when an attacker registered their address first. Needs the mailer, which now exists.
- **No "confirm your email" prompt**, so the [confirmation order](docs/authentication.md#confirming-an-account) has to be known rather than discovered.
- **Email Sending is in open beta** — treat delivery as best-effort; password login is deliberately the primary path.
- **A deploy costs one cold start and drops open WebSockets**: a Durable Object has exactly one container, so it is replaced rather than drained.
- **`package-lock.json` is a stub** while `deploy.yml` installs with `npm install`, so production installs are not pinned. CI uses pnpm with `--frozen-lockfile`.
