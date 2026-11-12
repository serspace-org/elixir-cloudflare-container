defmodule PocApp do
  @moduledoc """
  Minimal Plug application for Cloudflare Containers PoC.
  """
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  get "/" do
    send_resp(conn, 200, ~s({"ok": true, "message": "Hello from Elixir on Cloudflare Containers"}))
  end

  get "/health" do
    send_resp(conn, 200, "ok")
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end
