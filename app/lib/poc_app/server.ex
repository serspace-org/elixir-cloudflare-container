defmodule PocApp.Server do
  @moduledoc """
  Minimal HTTP server using :gen_tcp (zero external dependencies).
  """
  use GenServer

  def start_link(port: port) do
    GenServer.start_link(__MODULE__, port, name: __MODULE__)
  end

  @impl true
  def init(port) do
    {:ok, socket} = :gen_tcp.listen(port, [
      :binary,
      packet: :line,
      active: false,
      reuseaddr: true
    ])
    send(self(), :accept)
    {:ok, socket}
  end

  @impl true
  def handle_info(:accept, socket) do
    case :gen_tcp.accept(socket) do
      {:ok, client} ->
        serve(client)
      {:error, _} ->
        :ok
    end
    send(self(), :accept)
    {:noreply, socket}
  end

  defp serve(client) do
    case :gen_tcp.recv(client, 0) do
      {:ok, line} ->
        path = parse_path(line)
        :gen_tcp.send(client, response_for(path))
      _ ->
        :ok
    end
    :gen_tcp.close(client)
  end

  defp parse_path(line) do
    case line do
      "GET " <> rest ->
        rest |> String.split(" ") |> List.first() |> String.trim()
      _ ->
        "/"
    end
  end

  defp response_for("/health") do
    "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
  end

  defp response_for("/") do
    json = ~s({"ok": true, "message": "Hello from Elixir on Cloudflare Containers"})
    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(json)}\r\nConnection: close\r\n\r\n#{json}"
  end

  defp response_for(_) do
    "HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\nConnection: close\r\n\r\nnot found"
  end
end
