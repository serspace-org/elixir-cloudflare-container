// Raw Phoenix Channel client for /probe.
//
// Deliberately independent of LiveView: it opens its own Socket against
// "/socket" (which has longpoll disabled server-side), so a failure here
// means the WebSocket upgrade or the channel is broken, not LiveView.
import {Socket} from "phoenix"

const text = (id, value) => {
  const el = document.getElementById(id)
  if (el) { el.textContent = value }
}

export function startChannelProbe() {
  const root = document.getElementById("channel-probe")
  if (!root) { return null }

  const room = root.dataset.room || "lobby"

  // /socket requires a logged-in account and cannot read the session, so the
  // root layout mints a signed token into <meta name="user-token">. Without
  // one the upgrade is refused, which would show up here as an unexplained
  // error loop — so say what happened instead of connecting.
  const userToken = document.querySelector("meta[name='user-token']")?.getAttribute("content")
  if (!userToken) {
    text("probe-state", "not logged in — no socket token on this page")
    return null
  }

  const socket = new Socket("/socket", {params: {user_token: userToken}})
  let reconnects = 0
  let opened = false

  socket.onOpen(() => {
    // The first open is the connection; later ones are reconnects.
    if (opened) { text("probe-reconnects", ++reconnects) }
    opened = true
    text("probe-state", "open")
    text("probe-transport", socket.transport.name || socket.transport.constructor.name)
  })
  socket.onError(err => text("probe-state", `error: ${err && err.message || "unknown"}`))
  socket.onClose(() => text("probe-state", "closed"))

  socket.connect()

  const channel = socket.channel(`room:${room}`, {})
  const list = document.getElementById("probe-messages")

  const append = msg => {
    if (!list) { return }
    const li = document.createElement("li")
    li.className = "py-2"
    li.id = `probe-msg-${msg.id}`
    const who = document.createElement("span")
    who.className = "font-mono text-zinc-500"
    who.textContent = `${msg.nickname}: `
    li.appendChild(who)
    li.appendChild(document.createTextNode(msg.body))
    list.appendChild(li)
    li.scrollIntoView({block: "nearest"})
  }

  channel.on("new_msg", append)

  channel.join()
    .receive("ok", resp => {
      text("probe-state", "joined")
      text("probe-nickname", resp.nickname)
      text("probe-uptime", `${Math.round(resp.server.node_uptime_ms / 1000)}s`)
      text("probe-durability", resp.d1_ready ? "D1" : "ephemeral (D1 unreachable)")
      resp.messages.forEach(append)
    })
    .receive("error", resp => text("probe-state", `join failed: ${JSON.stringify(resp)}`))

  const form = document.getElementById("probe-form")
  const input = document.getElementById("probe-input")
  if (form && input) {
    form.addEventListener("submit", e => {
      e.preventDefault()
      const body = input.value.trim()
      if (!body) { return }
      channel.push("new_msg", {body})
        .receive("ok", resp => text("probe-durability", resp.durability))
        .receive("error", resp => text("probe-durability", `rejected: ${resp.reason}`))
      input.value = ""
    })
  }

  // Latency and liveness probe. It also keeps the socket busy, which is how
  // we check that the Durable Object's inactivity timeout counts WebSocket
  // traffic as activity — see docs/realtime.md.
  setInterval(() => {
    if (channel.state !== "joined") { return }
    const sent = Date.now()
    channel.push("ping", {client_ts: sent}, 5000)
      .receive("ok", resp => {
        text("probe-rtt", `${Date.now() - sent} ms`)
        text("probe-uptime", `${Math.round(resp.node_uptime_ms / 1000)}s`)
      })
      .receive("timeout", () => text("probe-rtt", "timeout"))
  }, 5000)

  return {socket, channel}
}
