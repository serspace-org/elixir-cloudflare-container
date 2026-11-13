defmodule AppWeb.PageController do
  use AppWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end

  def health(conn, _params) do
    send_resp(conn, 200, "ok")
  end

  @doc """
  Plain, non-LiveView page that drives the raw channel client.

  Keeping it off LiveView means a failure here points at the WebSocket
  transport or the channel, not at LiveView.
  """
  def probe(conn, _params) do
    render(conn, :probe, room: App.Chat.default_room())
  end

  @doc """
  Socket diagnostics as JSON, for `curl` and CI assertions.

  `node_uptime_ms` is the useful one: if it resets between polls, the
  container restarted rather than the socket merely reconnecting.
  """
  def socket_health(conn, _params) do
    {uptime_ms, _since_last} = :erlang.statistics(:wall_clock)
    room = App.Chat.default_room()

    json(conn, %{
      status: "ok",
      node: to_string(node()),
      node_uptime_ms: uptime_ms,
      room: room,
      present: map_size(AppWeb.Presence.list("room:" <> room)),
      d1_ready: App.Chat.d1_available?()
    })
  end
end
