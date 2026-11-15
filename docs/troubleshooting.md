# Troubleshooting

How to find out what this stack is actually doing, and a log of the bugs it has
already produced. Every one of those looked like something else first, which is
why the second half of this document exists.

The architecture puts four moving parts between a request and an answer — Worker,
Durable Object, container, and a gateway per binding — and each one fails
differently. Guessing which is involved is expensive; the commands below are
cheaper.

## Start here

```bash
# What the Worker is doing, live. The single most useful command in the repo.
pnpm exec wrangler tail phoenix-cf-container --format json

# Node identity, BEAM uptime, and whether the D1 gateway answers.
curl -s https://<host>/health/sockets

# What is actually stored, rather than what the app thinks it stored.
pnpm exec wrangler d1 execute DB --remote --json \
  --command "SELECT id, email, confirmed_at FROM users ORDER BY id"
```

`wrangler tail` is **live only** — there is no historical query. If something
already happened and you have no log, you have to reproduce it. Driving the app
yourself (below) is usually faster than asking a human to click again.

## Reading the Worker's logs

Each event carries an `entrypoint`, which is how you tell the gateways apart:

| `entrypoint` | What it is |
| --- | --- |
| `null` | The default fetch handler — a real client request |
| `D1Gateway` | The container talking to D1 over `d1.internal` |
| `MailGateway` | The container sending mail over `mail.internal` |

A healthy magic-link request looks like four events in order: the page load,
`D1Gateway GET /users?email=…`, `D1Gateway POST /user_tokens`, and
`MailGateway POST /send` carrying `MailGateway sent <id> to *@domain`.

**`outcome: ok` does not mean it worked.** A gateway that returns 400 or 503
still completed normally as far as the runtime is concerned. That is why every
rejection path in `src/index.ts` logs what was wrong — an event with
`outcome: ok` and no logs used to be ambiguous, and it cost a long evening.

## Did the deploy actually reach users?

```bash
curl -s https://<host>/health/sockets | grep -o '"node_uptime_ms":[0-9]*'
```

If the BEAM has been up longer than your last deploy, **the old image is still
serving**. The Durable Object does not replace a running container, and every
request pushes its inactivity deadline another 10 minutes out, so a busy site
can serve stale code indefinitely. `rollStaleContainer()` in `src/index.ts`
handles this by comparing the deployed image against the one the DO recorded
starting, and stopping the container when they differ — see
[How a deploy actually reaches users](deploy.md#how-a-deploy-actually-reaches-users).

Two things follow from that:

- Polling a URL to see whether your fix is live **prevents** it from going live.
- Changing a secret does **not** restart the container. Secrets arrive via
  `container.start()`, so `MAIL_FROM` and friends only take effect on the next
  start. Deploy (every deploy mints a new image tag) or idle it out.

## Inspecting D1

```bash
# Accounts and their confirmation state
pnpm exec wrangler d1 execute DB --remote --json \
  --command "SELECT id, email, confirmed_at, length(hashed_password) FROM users"

# Sessions and emailed tokens. `context` is 'session', 'login', or 'change:<email>'.
pnpm exec wrangler d1 execute DB --remote --json \
  --command "SELECT id, user_id, context, sent_to, inserted_at FROM users_tokens ORDER BY id DESC LIMIT 10"

# Which migrations D1 has
pnpm exec wrangler d1 execute DB --remote --command "SELECT * FROM d1_migrations"
```

A `login` token with no corresponding `MailGateway sent` line means Phoenix
minted the token and the send was rejected — the token is written first,
deliberately, so this distinction is visible.

## Email

```bash
# Is the domain onboarded, and with which DKIM selector?
pnpm exec wrangler email sending list
pnpm exec wrangler email sending settings mail.example.com
pnpm exec wrangler email sending dns get mail.example.com

# Addresses Cloudflare has stopped delivering to after a hard bounce.
# An empty list means no permanent bounce has been recorded.
cf email-sending suppressions list
```

`wrangler email sending send` reports only "Queued for:". The REST API returns
the delivery outcome, which is strictly more useful when diagnosing:

```bash
cf email-sending send --body '{
  "from": {"address": "auth@mail.example.com", "name": "App"},
  "to":   [{"address": "you@example.com"}],
  "subject": "Delivery check", "text": "hello"
}'
# → {"message_id": "<…>", "delivered": [], "queued": ["you@example.com"],
#    "permanent_bounces": [], "suppressed_recipients": []}
```

That path bypasses `MailGateway` entirely, which makes it a clean control: if a
REST send arrives and an app send does not, the bug is in the gateway or the
adapter, **not** in DNS, reputation or filtering. Verify the DNS chain
independently rather than assuming:

```bash
dig +short TXT cf-bounce._domainkey.mail.example.com   # DKIM, must align with From
dig +short TXT _dmarc.mail.example.com                 # policy
dig +short MX  cf-bounce.mail.example.com              # bounce handling
```

Bounces go to the return-path domain, which Cloudflare owns — so **a bounce
never reaches your inbox**. The suppression list and the dashboard are the only
places that record exists.

## Reproducing something without a browser

Most of this app's interesting paths are LiveView events, which `curl` cannot
reach. A small script can: fetch the page, pull `data-phx-session`,
`data-phx-static` and the CSRF token out of the HTML, open a WebSocket to
`/live/websocket`, `phx_join` the `lv:<id>` topic, then push the event.

Two things that will waste your time otherwise:

- **The session cookie must travel on the WebSocket handshake**, or the join is
  rejected as `stale`. Node's built-in `WebSocket` cannot set headers; the `ws`
  package can.
- Phoenix v2 framing is `[join_ref, ref, topic, event, payload]`, and a form
  event's `value` is a URL-encoded string, not an object.

`scripts/ws-smoke.mjs` does the equivalent for a plain channel and is the
closest working example in the repo.

## What has actually gone wrong

Four defects reached production while authentication was being added. They are
recorded because the *shape* of each one repeats, and because every one of them
presented as a different problem than it was.

### A deploy that changed nothing

**Symptom** — CI green, migrations applied, and `/users/register` returned 404
while `/chat` returned 200.

**Cause** — The Durable Object skips `start()` whenever a container is already
running, and the only thing that stops one is the inactivity timeout, which
every request renews. The old image served indefinitely.

**Lesson** — Reloading the URL to check whether the fix is live is what kept it
from going live. Fixed by `rollStaleContainer()`.

### Registration failed with a gateway error

**Symptom** — "We could not create your account right now."

**Cause** — D1 **throws** on `undefined` in `bind()` rather than treating it as
NULL, and `confirmed_at` is absent at registration.

**Lesson** — `tasks` and `messages` have no nullable columns, so nothing in the
original app had ever bound an absent value. The local SQLite stand-in binds
`nil` happily, so the test suite could not see it. Fixed by `bindable()`.

### Cloudflare error 1101 on logging in

**Symptom** — An opaque "Worker threw exception" page. The account and session
token were created at the exact second of the error, so the request had
succeeded.

**Cause** — The proxy did not set `redirect`, so `fetch` defaulted to following
redirects. Phoenix answers a form POST with a 302, following it meant replaying
a body that arrived as a stream, and that throws.

**Lesson** — Nothing before authentication could trigger it: every other POST
in this app goes over a WebSocket, and all three auth form POSTs redirect. Fixed
by `redirect: "manual"`, plus a 503 fallback so no throw reaches a user as a
1101, plus an assertion in `ws-smoke.mjs`.

### No account email was ever sent

**Symptom** — Magic-link and confirmation emails never arrived, while sends
through the CLI and REST API arrived normally. Hours went into DNS, DKIM
alignment, reputation, spam filtering and Cloudflare's queue.

**Cause** — `MailGateway` read `reply_to` as
`payload.reply_to === undefined ? … : readAddress(…)`. JSON has no `undefined`,
so an absent reply-to arrived as `null`, `readAddress(null)` returned `null`,
and `null` is that module's encoding for *invalid* — a 400 before
`env.EMAIL.send()` was ever called, on 100% of messages.

**Lesson** — The 400 logged nothing, and the Worker invocation still reported
`outcome: ok`, so the trace was indistinguishable from success. Two separate
rules came out of it, both now in `CLAUDE.md`: `null` means absent on every
gateway, and a rejection path must always log.

### The pattern

Two of the four are the same mistake — null-versus-undefined across the
Elixir → JSON → TypeScript boundary — and all four share a cause: **the
Worker's gateways have no tests against the real bindings.** The Elixir half is
tested against a `Req.Test` stub, the SQL against a local SQLite stand-in, and
neither can see the Worker's own code. A Miniflare harness covering `D1Gateway`
and `MailGateway` would have caught both null bugs before deploy. It is the
most valuable thing missing from this repo.
