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
