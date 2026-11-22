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

  Behind the `:require_authenticated_user` plug, like `/chat`: the socket it
  opens needs an account, and the token it authenticates with is minted into
  the root layout for the signed-in scope.
  """
  def probe(conn, params) do
    room = App.Chat.room_or_default(params["room"])

    render(conn, :probe,
      room: room,
      nickname: App.Chat.sender_name(conn.assigns.current_scope),
      share_url: url(~p"/chat/#{room}"),
      probe_url: url(~p"/probe/#{room}")
    )
  end

  @doc """
  Socket diagnostics as JSON, for `curl` and CI assertions.

  `node_uptime_ms` is the useful one: if it resets between polls, the
  container restarted rather than the socket merely reconnecting.
  """
  def socket_health(conn, params) do
    {uptime_ms, _since_last} = :erlang.statistics(:wall_clock)
    room = App.Chat.room_or_default(params["room"])

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
