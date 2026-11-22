# WebSockets, channels and the chat demo

## Who can chat

Both chat surfaces require a logged-in account, like `/tasks`:

* `/chat` and `/chat/:room` sit in the `live_session :require_authenticated_user` block, so the plug redirects the initial request and the `on_mount` hook redirects the socket.
* `/probe` and `/probe/:room` are controller routes behind the `:require_authenticated_user` plug.
* `/socket` authenticates on its own. A plain `Phoenix.Socket` cannot read the session — `connect/3` sees only params — so the root layout mints a signed token (`AppWeb.UserAuth.user_socket_token/1`) into `<meta name="user-token">`, `assets/js/channel_probe.js` hands it back as a socket param, and `AppWeb.UserSocket` verifies it and resolves the account. A missing, expired or forged token is a refused upgrade. Logging out broadcasts `"disconnect"` on that socket's id as well as the LiveView one, so an open `/probe` tab cannot keep sending as a session that is gone.

The sender of a message is therefore the session's account, never a name from the client: `App.Chat.create_message/3` takes an `App.Accounts.Scope` and matches it, and `user_id`/`nickname` are set from it rather than cast (see `App.Chat.Message.changeset/2`). The display name is the email's local part (`App.Accounts.User.display_name/1`), stored on the row as it was at write time, so renaming an account never rewrites history.

Reads are *not* scoped to the sender, which is the difference from tasks: a room is a shared space whose slug is the capability, so anyone with an account and the link sees the whole transcript. Rows written before migration `0005` have a NULL `user_id` and render under the nickname they were written with.

## Sessions and sharing

Both chat clients are room-scoped, so a session is just a URL you can hand to someone with an account:

| URL | What it is |
| --- | --- |
| `/chat` | LiveView client in the default `lobby` room |
| `/chat/:room` | LiveView client in a named room |
| `/probe/:room` | raw-channel client in the same room |

**New session** on `/chat` generates a fresh room slug and navigates to it; the share box next to it holds the link to send. Rooms are isolated — messages, history and presence are all per-room. Room names are validated against `^[a-z0-9][a-z0-9-]{0,63}$` (`App.Chat.valid_room?/1`) because the name reaches both a channel topic and the database; anything else falls back to `lobby`. Presence is keyed by user id, so two tabs of the same account are one person in the roster.

To share a local session with someone on your network, note that dev is bound to loopback — change `http: [ip: {127, 0, 0, 1}]` to `ip: {0, 0, 0, 0}` in `app/config/dev.exs` and give them `http://<your-lan-ip>:4000/chat/<room>`. `check_origin` is already disabled in dev.

## Two sockets, verified separately

Phoenix's two socket paths are verified separately, because they fail differently:

| Route | Socket | What a failure tells you |
| --- | --- | --- |
| `/chat/:room` | LiveView on `/live` | LiveView real-time updates |
| `/probe/:room` | raw `Phoenix.Channel` on `/socket`, **no long-poll fallback** | the WebSocket upgrade itself |

The reason for two is that `assets/js/app.js` sets `longPollFallbackMs`, so a broken WebSocket upgrade makes LiveView quietly fall back to long-polling and *everything still looks fine*. `/socket` sets `longpoll: false`, and both pages print the transport actually in use, so a degraded connection is visible rather than invisible.

## What to check

```bash
# /socket needs a login, so the script signs in first (and asserts the
# form-POST redirect survives the Worker's proxy on the way).
export SMOKE_EMAIL=you@example.com SMOKE_PASSWORD=...
pnpm ws:smoke https://<your-host>   # scripted: handshake, join, broadcast round trip
SMOKE_ROOM=standup pnpm ws:smoke https://<your-host>   # in a specific room

curl https://<your-host>/health/sockets        # add ?room=<room> for a specific room
# {"status":"ok","node":"...","node_uptime_ms":123456,"present":0,"d1_ready":true,...}
```

By hand, open `/chat/<room>` and `/probe/<room>` side by side (or share the link and have someone join from their own machine):

1. **Transport** on both pages must say `websocket`. `/chat` keeps its diagnostics collapsed, but opens the card and turns it red if the LiveView socket degraded to long-polling.
2. **Cross-socket fan-out** — a message sent in `/probe` must appear in `/chat` and vice versa. That exercises `Phoenix.PubSub` between two different socket implementations.
3. **Presence** — the roster above the transcript, and *Online now* in the diagnostics card, must rise and fall as accounts open and close tabs.
4. **Round trip** on `/probe` is the real latency through Worker → Durable Object → container.
5. **Node uptime** is the one to watch on a reconnect: if it *keeps climbing*, only the socket reconnected; if it *resets to zero*, the container cold-started and you lost BEAM state. Persisted history survives either way, which is the point of storing it in D1.
6. **Idle survival** — leave a tab open and idle for more than 10 minutes (the Durable Object's `INACTIVITY_TIMEOUT_MS`). Phoenix heartbeats every 30s, so the socket should stay up and node uptime should keep climbing. If it does not, WebSocket traffic is not counting as container activity and the timeout needs raising or a keepalive adding.

When the D1 gateway is unreachable — no `DB` binding, or the local gateway disabled — chat still works but marks itself *ephemeral* and keeps no history, so the transport can be tested on its own.
