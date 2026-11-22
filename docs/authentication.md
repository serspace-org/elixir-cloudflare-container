# Authentication

Generated with `mix phx.gen.auth Accounts User users --live --hashing-lib bcrypt`, then adapted to this app's data layer. You get the generator's full scope-based stack — `AppWeb.UserAuth` (plug + `on_mount`), session tokens in the database, remember-me cookie, sudo mode, and the `@current_scope` assign — with Cloudflare D1 underneath instead of Postgres.

Register at `/users/register` with an email and a password and you are logged in immediately. **No email is sent**, by design for now: see [Mailer](#mailer).

An account gates the owned data: `/tasks`, chat itself, and the owned/shared chat rooms managed at `/rooms` ([details](realtime.md#owned-and-shared-rooms)). Identity also rides the raw channel socket as a signed `user_token` connect param (`AppWeb.UserSocket`), which is why log-out and the password flows broadcast a disconnect to `AppWeb.UserAuth.user_socket_topic/1` — that socket authenticates outside the session, so deleting the session row alone would leave it connected.

## What changed from the generated code, and why

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

## Confirming an account

Registration leaves `confirmed_at` empty, and nothing in the app gates on it — so this only matters when you want magic-link login to work.

The order is not guessable, which is a usability problem rather than a bug:

1. `/users/log-in` → "Log in with email" sends an email titled **"Confirmation instructions"**, not a login link, because the account is unconfirmed (`UserNotifier.deliver_login_instructions/2` branches on it).
2. Opening that link **while logged out is refused** — "Please log in with your password to confirm your account." The account has a password and is unconfirmed, which is exactly the credential pre-stuffing case the mitigation blocks.
3. Log in with the password first, then open the link in the same browser, and it confirms the account.
4. From then on "Log in with email" sends a real magic link that works on its own.

The clean fix is an "unconfirmed — confirm your email" banner with a resend button shown after password login, so confirmation happens on the natural path while the user is already authenticated. Not implemented; see [Known gaps](../README.md#known-gaps).

## Mailer

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
