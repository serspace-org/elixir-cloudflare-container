# WebSockets, channels and the chat demo

## Sessions and sharing

Both chat clients are room-scoped, so a session is just a URL you can hand to someone:

| URL | What it is |
| --- | --- |
| `/chat` | LiveView client in the default `lobby` room |
| `/chat/:room` | LiveView client in a named room |
| `/probe/:room` | raw-channel client in the same room |
| `/rooms` | manage owned and shared rooms (requires an account) |

**New session** on `/chat` generates a fresh room slug and navigates to it; the share box next to it holds the link to send. Rooms are isolated — messages, history and presence are all per-room. Room names are validated against `^[a-z0-9][a-z0-9-]{0,63}$` (`App.Chat.valid_room?/1`) because the name reaches both a channel topic and the database; anything else falls back to `lobby`. `?as=<name>` sets your display name, and the **Rename** field changes it live.

### Owned and shared rooms

Rooms opened through a link stay what they always were: open to anyone with the slug, no account needed. A logged-in user can additionally **create** rooms at `/rooms`, which claims a slug in the `rooms` table:

- A **private** room admits only its owner and the accounts it is shared with. Everyone else — including anonymous visitors with the link — is denied: the LiveView bounces to `/chat` with a flash, and a channel join is refused with `"unauthorized"` (deliberately distinct from `"unknown room"`).
- A **link-open** room behaves like an unclaimed one but has an owner, who can rename it, flip visibility, or delete it (deleting takes the transcript with it, in one gateway batch).
- **Sharing is with existing accounts only** — there is no invitation email (delivery may not even be configured; see [Authentication](authentication.md)). Link visibility is the escape hatch for everyone else. Revoking a member broadcasts `{:access_revoked, id}` so their live sessions disconnect immediately — authorization is otherwise only checked on entry.

The raw `/socket` carries the identity: the root layout renders a short-lived `Phoenix.Token` for the logged-in user, `channel_probe.js` passes it as the `user_token` connect param, and `AppWeb.UserSocket` resolves it to a scope (a bad token refuses the connection rather than silently downgrading to anonymous). Authorization itself is enforced in SQL in the Worker's `D1Gateway` — see the ownership rules in [Architecture](architecture.md).

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
