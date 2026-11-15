#!/usr/bin/env node
//
// Post-deploy WebSocket smoke test.
//
// Opens a real WebSocket to /socket, joins the chat channel, sends a message
// and asserts the broadcast comes back. The point is to fail CI when the
// upgrade through the Worker and Durable Object breaks — the browser would
// otherwise long-poll and look healthy.
//
// Usage: node scripts/ws-smoke.mjs https://your-worker.example.com
//
// Uses Node's built-in WebSocket (Node 22+); no dependencies.

const target = process.argv[2] || process.env.SMOKE_URL
if (!target) {
  console.error("usage: node scripts/ws-smoke.mjs <https://host>")
  process.exit(2)
}

const TIMEOUT_MS = Number(process.env.SMOKE_TIMEOUT_MS || 60_000)
const ROOM = process.env.SMOKE_ROOM || "lobby"
const body = `ws-smoke ${process.env.GITHUB_SHA || "local"} ${Date.now()}`

const base = new URL(target)
const wsUrl = new URL("/socket/websocket", base)
wsUrl.protocol = base.protocol === "http:" ? "ws:" : "wss:"
wsUrl.searchParams.set("vsn", "2.0.0")

const fail = message => { console.error(`FAIL  ${message}`); process.exit(1) }
const pass = message => console.log(`ok    ${message}`)

// The container cold-starts on the first request, so warm it up (and prove
// /health works) before timing the socket.
const health = await fetch(new URL("/health", base), {redirect: "follow"})
if (!health.ok) { fail(`GET /health returned ${health.status}`) }
pass("GET /health")

const sockets = await fetch(new URL("/health/sockets", base)).then(r => r.json())
pass(`node ${sockets.node}, uptime ${Math.round(sockets.node_uptime_ms / 1000)}s, d1_ready=${sockets.d1_ready}`)

// A form POST that Phoenix answers with a redirect. Nothing in the Elixir
// suite can reach this: it is the Worker's proxy that has to hand the 302
// back instead of chasing it, and chasing it threw a TypeError — the request
// body arrives as a stream and cannot be replayed — which Cloudflare served
// as error 1101. Every auth form POST redirects, so this class of bug is one
// deploy away whenever the proxy changes.
const loginPage = await fetch(new URL("/users/log-in", base))
const cookie = (loginPage.headers.getSetCookie?.() || []).map(c => c.split(";")[0]).join("; ")
const csrf = ((await loginPage.text()).match(/name="csrf-token" content="([^"]+)"/) || [])[1]
if (!csrf) { fail("could not read a CSRF token from /users/log-in") }

const redirecting = await fetch(new URL("/users/log-in", base), {
  method: "POST",
  redirect: "manual",
  headers: {"content-type": "application/x-www-form-urlencoded", cookie},
  // Deliberately wrong credentials: the point is the 302, not a session.
  body: new URLSearchParams({
    _csrf_token: csrf,
    "user[email]": "ws-smoke-nobody@example.com",
    "user[password]": "definitely not the password",
  }).toString(),
})
if (redirecting.status !== 302) {
  fail(`POST /users/log-in returned ${redirecting.status}, expected a 302 passed through`)
}
if (!redirecting.headers.get("location")) {
  fail("POST /users/log-in returned a 302 with no Location header")
}
pass(`form POST redirect passed through (302 -> ${redirecting.headers.get("location")})`)

const socket = new WebSocket(wsUrl)
let ref = 0
const topic = `room:${ROOM}`
// Phoenix v2 serializer frame: [join_ref, ref, topic, event, payload]
const send = (event, payload, joinRef = "1") =>
  socket.send(JSON.stringify([joinRef, String(++ref), topic, event, payload]))

const timer = setTimeout(() => fail(`timed out after ${TIMEOUT_MS}ms`), TIMEOUT_MS)
const started = Date.now()

socket.addEventListener("open", () => {
  pass(`websocket open in ${Date.now() - started}ms`)
  socket.send(JSON.stringify(["1", String(++ref), topic, "phx_join", {}]))
})

socket.addEventListener("error", event => fail(`socket error: ${event.message || event.type}`))

socket.addEventListener("close", event => {
  // A clean close before we finish means the run never reached the assertions.
  clearTimeout(timer)
  fail(`socket closed early (code ${event.code})`)
})

socket.addEventListener("message", ({data}) => {
  const [, , , event, payload] = JSON.parse(data)

  if (event === "phx_reply" && payload.response?.nickname) {
    if (payload.status !== "ok") { fail(`join rejected: ${JSON.stringify(payload.response)}`) }
    pass(`joined ${topic} as ${payload.response.nickname} (${payload.response.messages.length} in history)`)
    send("new_msg", {body})
    return
  }

  if (event === "new_msg" && payload.body === body) {
    pass("message broadcast round trip")
    clearTimeout(timer)
    // Remove the close handler so the deliberate close below is not a failure.
    socket.onclose = null
    socket.close()
    console.log("\nWebSocket smoke test passed")
    process.exit(0)
  }

  if (event === "phx_error" || event === "phx_close") {
    fail(`channel ${event}: ${JSON.stringify(payload)}`)
  }
})
