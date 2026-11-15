# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Phoenix 1.8 LiveView app packaged as a Docker container and served on Cloudflare Containers, fronted by a Worker + Durable Object. See `README.md` for setup/deploy prose; `app/AGENTS.md` holds the Phoenix/Elixir/LiveView coding rules and applies to everything under `app/` — read it before touching Elixir or HEEx.

## Architecture

```
Client (HTTPS) → Worker (src/index.ts) → ElixirContainer (Durable Object) → container, Phoenix on :4000
                                                                                  ↓ http://d1.internal
                                                              D1Gateway (WorkerEntrypoint) → D1 binding `DB`

dev: no Worker — App.D1 talks to App.D1.LocalGateway on 127.0.0.1:4100 (SQLite file)
```

Seven pieces that only make sense together:

1. **`src/index.ts` — Worker + `ElixirContainer` Durable Object.** The default fetch routes *every* request to a single DO instance (`getByName("singleton")`). The DO starts the container on first request, polls `GET /health` until 200 (up to ~30s), sets a 10-minute inactivity timeout, then proxies HTTP and WebSocket traffic verbatim to port 4000, injecting `x-forwarded-proto: https`. Container env (`SECRET_KEY_BASE`, `PHX_HOST`, `PORT`) is passed at `container.start()` from Worker secrets — the image carries no config.

   **A deploy does not replace a running container by itself** — `startAndWait()` skips `start()` while one is running, and every request renews the inactivity deadline, so an old image can keep serving indefinitely while the deploy reports success. `rollStaleContainer()` closes that: the DO records the image it started in its storage and stops the container when a deploy changes it. Don't remove it, and don't switch the comparison to `container.inspect()` — comparing against what we started is what keeps an unrecorded container stale and a string-format difference from becoming a restart loop.

2. **`MailGateway` (also `src/index.ts`) — the email path.** Same shape as the D1 gateway below: `interceptOutboundHttp("mail.internal", ...)`, and `App.Mailer.Gateway` (a Swoosh adapter) POSTs to it. Exists so no Email Sending token — which is account-wide — ever lands in the container image. The gateway pins the sender from `MAIL_FROM`, ignores the caller's `from`, allows one recipient, and refuses cc/bcc/attachments/headers; `App.Mailer.Gateway` refuses the same set rather than dropping it. `MAIL_FROM` gates the whole path: unset, and the intercept is never registered, the mailer stays `Swoosh.Adapters.Local`, and `App.Accounts.email_delivery_available?/0` keeps the mail-dependent flows hidden. Changing either half means changing the other, as with D1.

3. **`D1Gateway` (also `src/index.ts`) — the database path.** Before starting the container, the DO registers `container.interceptOutboundHttp("d1.internal", ctx.exports.D1Gateway(...))`. Phoenix then talks to D1 by making plain HTTP calls to `http://d1.internal/tasks...` (`App.D1`, using `Req`). Nothing is exposed publicly and no DB credentials exist in the image. This requires `compatibility_flags = ["enable_ctx_exports"]` in `wrangler.toml`, and the gateway is only registered when `env.DB` exists.

   **Adding a table/endpoint means editing four places in lockstep**: a SQL migration in `cloudflare/migrations/`, a route + parameterized query in `D1Gateway`, a client function in `app/lib/app/d1.ex`, and the same route in `App.D1.LocalGateway.Router` (the dev/test stand-in — drift between the two makes local runs lie about production). Keep all SQL parameterized (`?1`-style binds). `tasks`, `messages`, `users` and `users_tokens` are all wired this way — copy any of them.

   `PATCH /users/:id` is the only route that writes more than one statement: it updates the user and optionally deletes their tokens inside a D1 `batch` (one implicit transaction), mirrored locally by `App.D1.LocalGateway.transaction/1`. That batch is what replaces the `Repo.transact/1` the auth generator relied on — don't split it into two requests.

4. **D1 is not an Ecto repo.** `App.Tasks.Task` is an `embedded_schema` used purely for casting/validation; `App.Tasks` applies the changeset with `Changeset.apply_action/2` and persists via `App.D1`. `App.Accounts.User` and `App.Accounts.UserToken` follow the same pattern. `mix ecto.gen.migration` / `mix ecto.migrate` do **not** apply to D1 data. `App.Repo` (Postgres) and `App.Release.migrate` are vestigial — both are no-ops unless `DATABASE_URL` is set (see `App.Application.start/2`, which only supervises `App.Repo` when that env var exists).

5. **`App.D1.LocalGateway` — local persistence without Docker.** Compiled only outside `:prod` (Exqlite is a dev/test dep) and started only when `:d1_local_gateway` is configured, which `config/dev.exs` does alongside pointing `:d1_url` at `http://127.0.0.1:4100`. It serves `D1Gateway`'s HTTP contract from `app/priv/d1_local.sqlite3`, applying `cloudflare/migrations/*.sql` on boot (idempotent, tracked in a `local_migrations` table) — so `mix phx.server` gets real, restart-surviving persistence and the migrations get exercised locally. `App.Application` reaches it through a module attribute (`@local_d1`) so `:prod` never compiles a reference to a module that isn't there. It does **not** cover the `d1.internal` outbound intercept or real D1; that still needs `wrangler dev`.

6. **`App.Accounts` — `mix phx.gen.auth` without a Repo.** Generated with `mix phx.gen.auth Accounts User users --live --hashing-lib bcrypt`, then ported: every `Repo.*` became a gateway call, and the generator's `UserToken.verify_*_query/1` became a fetch by `{context, token}` plus a `*_valid?/1` check, so the validity windows stay in `App.Accounts.UserToken` where the generator put them. `unsafe_validate_unique/3` is a read through the gateway; the unique index on `lower(users.email)` is the real check and its 409 becomes a changeset error. Emails compare case-insensitively via `lower(email)` because D1 has no `citext`; token bytes are stored as lowercase hex; timestamps are `TEXT` in SQLite's `CURRENT_TIMESTAMP` format.

   **No mail provider is configured**, and the generated notifier assumed one: the Local adapter plus `config :swoosh, local: false` in `config/prod.exs` means delivering exits with `:noproc`. `UserNotifier.delivery_configured?/0` gates every send (`App.Accounts.email_delivery_available?/0` is the context-level name), the magic-link and email-change forms are not rendered while it is false, and no token is written for an email that cannot be sent. Configuring an adapter opens both flows with no code change — don't hardcode the guard either way.

   **Registration takes a password and sends no email** (there is no mail provider yet — see the README's Authentication section), which `mix help phx.gen.auth` warns enables credential pre-stuffing. The prescribed mitigation is load-bearing, not decoration: `login_user_by_magic_link/2` takes the current user and refuses to confirm an unconfirmed, password-holding account unless the requester is already logged in as that user, and `AppWeb.UserLive.Confirmation` mirrors that check in the UI. Don't drop either when wiring the mailer; add a password-reset flow instead, which is what lets a victim recover.

7. **Two socket paths, verified separately.** `/chat` (`AppWeb.ChatLive`) runs on LiveView's `/live` socket; `/probe` runs a plain-JS `Phoenix.Channel` client (`assets/js/channel_probe.js`) on `/socket`, mounted with `longpoll: false`. The split is deliberate: `app.js` sets `longPollFallbackMs`, so a broken WebSocket upgrade degrades LiveView to long-polling *silently*. Both pages display the live transport, and `GET /health/sockets` returns the same facts as JSON. Keep `longpoll: false` on `/socket` and keep the transport visible — removing either re-hides the failure mode this demo exists to catch. `scripts/ws-smoke.mjs` (`pnpm ws:smoke <url>`) asserts the handshake, join and broadcast round trip, and runs post-deploy in CI when the `SMOKE_URL` repo variable is set.

   Rooms are shareable sessions: `/chat/:room` and `/probe/:room`, with slugs generated by `App.Chat.new_room/0`. A room name reaches both a channel topic and the database, so it is validated with `App.Chat.valid_room?/1` in `RoomChannel.join/3` and coerced with `room_or_default/1` at the web edge — keep both.

   `App.Chat` broadcasts on `"chat:<room>"`, deliberately *not* the `"room:<room>"` channel topic — a channel is already subscribed to its own topic, so broadcasting there delivers every message to `RoomChannel` twice. Chat degrades to in-memory (`:ephemeral`) when the D1 gateway is unreachable so the transport can be tested without a database.

## Commands

Elixir (run from `app/`):

```bash
mix setup                      # deps + assets (ecto.setup needs local Postgres)
mix deps.get && mix assets.setup && mix assets.build   # the Postgres-free equivalent
mix phx.server                 # dev server on :4000, with local D1 persistence on :4100
rm priv/d1_local.sqlite3       # reset the local D1 stand-in database
mix test                       # no Postgres needed: the `test` alias only runs ecto.create/
                               # ecto.migrate when DATABASE_URL is set (see mix.exs)
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
pnpm ws:smoke https://<host>                                            # WebSocket/channel smoke test
```

**Deploy from CI, not locally, on Apple Silicon.** `wrangler deploy` cross-builds the `linux/amd64` image under QEMU and the BEAM crashes during dependency compilation. Pushing to `main` runs `.github/workflows/deploy.yml` on native AMD64 `ubuntu-latest`. The `ERL_FLAGS="+JMsingle true"` lines in both Dockerfile stages are a workaround for this same QEMU bug — don't remove them.

D1 migrations are applied by CI **before** `wrangler deploy` (`.github/workflows/deploy.yml`), using the `DB` binding so no database name is duplicated there. Code therefore cannot ship ahead of its schema, and a failed migration blocks the deploy. Keep migrations additive anyway — the previous version keeps serving traffic while the new one rolls out. Applying by hand is only for getting schema live ahead of a deploy; the command is idempotent.

## Gotchas

- D1 calls in tests are stubbed with `Req.Test` via `App.D1Stub` (`:d1_req_options` in `config/test.exs`). Channel and LiveView tests must be **non-async** — the stub is resolved in shared mode because the request is made from the channel/LiveView process, not the test process.
- For the auth tests, hand-written stubs would be lying about SQL that has to actually run (unique index, `RETURNING`, the batched update-and-delete), so `App.D1Stub.stub_d1_sqlite!/1` points the stub at `App.D1.LocalGateway.Router` over a throwaway SQLite file built from `cloudflare/migrations` — per-test isolation, the way the Ecto sandbox would give it. Use it (`setup :stub_d1_sqlite!`) for anything touching `App.Accounts`.
- `App.AccountsFixtures` reads rows back with `App.D1.LocalGateway.query/2` rather than through the gateway's HTTP contract, deliberately: test-only needs (backdating a token, clearing a password hash) must not become gateway routes.
- A `phx-hook` that only pushes events must **not** sit on a `phx-update="ignore"` element; that would block the server from updating the element it reports into (this bit the `/chat` diagnostics card).
- `/health` must stay unauthenticated, fast, and excluded from `force_ssl` (`config/prod.exs`) — the DO's readiness poll depends on it, and the container never becomes ready if it redirects.
- **D1 rejects `undefined` in `bind()`** — it throws rather than treating it as NULL — while `App.D1.LocalGateway` binds `nil` for the same case without complaint. So an absent optional value must go through `bindable()` in `D1Gateway` before it reaches `bind()`. This is the one gateway difference the mirrored HTTP contract cannot catch: `tasks` and `messages` have no nullable columns, so nothing bound an absent value until `users` arrived, and registration 500ed in production with a full green test suite.
- Container disk is ephemeral. Durable state belongs in D1.
- `App.D1.LocalGateway` binds port 4100, so only one dev server runs at a time — a second one fails to boot there, and the error names Bandit rather than the port.
- Assets are Elixir-managed (`esbuild`/`tailwind` Hex packages); there is no Node.js in the Docker build and no `assets/package.json`. Tailwind v4, no `tailwind.config.js`.
- Secrets (`SECRET_KEY_BASE`, `PHX_HOST`) are Worker secrets set with `wrangler secret put`, mirrored into `.dev.vars` for local dev.
