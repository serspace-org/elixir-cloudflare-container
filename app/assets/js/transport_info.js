// Reports the LiveView socket's real transport to the server.
//
// This matters because app.js sets `longPollFallbackMs`, so a broken
// WebSocket upgrade silently degrades to long-polling and everything still
// *looks* fine. The /chat diagnostics card shows what this hook reports, so
// a degraded transport is visible instead of invisible.
//
// The hook only pushes events and never touches the DOM, so the element it is
// attached to must NOT be `phx-update="ignore"` — that would stop the server
// from updating the very card this reports into.
export const TransportInfo = {
  mounted() {
    this.reconnects = 0
    this.report()

    const socket = this.liveSocket()
    if (socket) {
      socket.onError(() => { this.reconnects++ })
      socket.onOpen(() => this.report())
    }

    // Transport can change under us (WS dropping to long-poll), so re-check.
    this.timer = setInterval(() => this.report(), 5000)
  },

  destroyed() { clearInterval(this.timer) },

  liveSocket() {
    return window.liveSocket && window.liveSocket.getSocket ? window.liveSocket.getSocket() : null
  },

  report() {
    const socket = this.liveSocket()
    const transport = socket && socket.transport
      ? (transport => transport.name || transport.constructor.name)(socket.transport)
      : "unknown"

    this.pushEvent("transport_info", {
      transport,
      websocket: /websocket/i.test(transport),
      reconnects: this.reconnects,
      user_agent: navigator.userAgent
    })
  }
}
