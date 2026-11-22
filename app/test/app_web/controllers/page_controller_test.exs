defmodule AppWeb.PageControllerTest do
  # Not async: the D1 stub is resolved in shared mode. See App.D1Stub.
  use AppWeb.ConnCase, async: false

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Peace of mind from prototype to production"
  end

  test "GET /health", %{conn: conn} do
    assert conn |> get(~p"/health") |> response(200) == "ok"
  end

  describe "GET /probe" do
    setup :stub_d1_sqlite!

    test "redirects a visitor to the log-in page", %{conn: conn} do
      conn = get(conn, ~p"/probe")

      assert redirected_to(conn) == ~p"/users/log-in"
    end

    test "serves the raw channel client to a logged-in user", %{conn: conn} do
      %{conn: conn} = register_and_log_in_user(%{conn: conn})

      html = conn |> get(~p"/probe") |> html_response(200)
      assert html =~ ~s|id="channel-probe"|
      assert html =~ ~s|data-room="lobby"|
      # The socket cannot read the session, so the page carries a signed token.
      assert html =~ ~s|name="user-token"|
    end
  end

  test "GET /health/sockets reports node and presence facts", %{conn: conn} do
    stub_d1_messages()

    body = conn |> get(~p"/health/sockets") |> json_response(200)

    assert body["status"] == "ok"
    assert body["room"] == "lobby"
    assert body["present"] == 0
    assert body["d1_ready"]
    assert is_integer(body["node_uptime_ms"])
  end
end
