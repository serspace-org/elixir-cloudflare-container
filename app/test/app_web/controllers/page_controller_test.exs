defmodule AppWeb.PageControllerTest do
  use AppWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Peace of mind from prototype to production"
  end

  test "GET /health", %{conn: conn} do
    assert conn |> get(~p"/health") |> response(200) == "ok"
  end

  test "GET /probe serves the raw channel client", %{conn: conn} do
    html = conn |> get(~p"/probe") |> html_response(200)
    assert html =~ ~s|id="channel-probe"|
    assert html =~ ~s|data-room="lobby"|
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
