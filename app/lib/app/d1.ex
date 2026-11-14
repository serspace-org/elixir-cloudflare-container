defmodule App.D1 do
  @moduledoc """
  HTTP client for the private D1 gateway exposed by the Cloudflare Worker.

  The Worker registers a `d1.internal` outbound HTTP intercept for the
  container (see `D1Gateway` in `src/index.ts`), backed by the Worker's
  `DB` D1 binding. The hostname resolves only inside the container, so the
  database is never exposed to the public internet and no credentials ship
  in the image.

  Functions return raw row maps; the contexts (`App.Tasks`, `App.Chat`)
  convert them into structs.
  """

  require Logger

  @base_url Application.compile_env(:app, :d1_url, "http://d1.internal")

  ## Messages (chat demo)

  @doc """
  Returns up to `limit` messages for `room`, oldest first.
  """
  @spec list_messages(String.t(), pos_integer()) :: {:ok, [map()]} | {:error, term()}
  def list_messages(room, limit \\ 50) when is_binary(room) and is_integer(limit) do
    query = URI.encode_query(%{"room" => room, "limit" => limit})

    case request(:get, "/messages?" <> query) do
      {:ok, %{"messages" => rows}} -> {:ok, rows}
      {:error, _reason} = error -> error
    end
  end

  @doc "Persists a chat message and returns its row."
  @spec create_message(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def create_message(room, nickname, body)
      when is_binary(room) and is_binary(nickname) and is_binary(body) do
    case request(:post, "/messages", %{room: room, nickname: nickname, body: body}) do
      {:ok, %{"message" => row}} -> {:ok, row}
      {:error, _reason} = error -> error
    end
  end

  ## Tasks

  @doc "Returns all task rows, newest first."
  @spec list_tasks() :: {:ok, [map()]} | {:error, term()}
  def list_tasks do
    case request(:get, "/tasks") do
      {:ok, %{"tasks" => rows}} -> {:ok, rows}
      {:error, _reason} = error -> error
    end
  end

  @doc "Creates a task and returns its row."
  @spec create_task(String.t()) :: {:ok, map()} | {:error, term()}
  def create_task(title) when is_binary(title) do
    case request(:post, "/tasks", %{title: title}) do
      {:ok, %{"task" => row}} -> {:ok, row}
      {:error, _reason} = error -> error
    end
  end

  @doc "Returns the task row for `id`, or `{:error, :not_found}`."
  @spec get_task(integer() | String.t()) :: {:ok, map()} | {:error, term()}
  def get_task(id) do
    case request(:get, "/tasks/#{id}") do
      {:ok, %{"task" => row}} -> {:ok, row}
      {:error, _reason} = error -> error
    end
  end

  @doc "Updates a task and returns its row."
  @spec update_task(integer() | String.t(), map()) :: {:ok, map()} | {:error, term()}
  def update_task(id, attrs) when is_map(attrs) do
    case request(:patch, "/tasks/#{id}", attrs) do
      {:ok, %{"task" => row}} -> {:ok, row}
      {:error, _reason} = error -> error
    end
  end

  @doc "Deletes the task with `id`."
  @spec delete_task(integer() | String.t()) :: :ok | {:error, term()}
  def delete_task(id) do
    case request(:delete, "/tasks/#{id}") do
      {:ok, _body} -> :ok
      {:error, _reason} = error -> error
    end
  end

  ## Transport

  defp request(method, path, body \\ nil) do
    options =
      [method: method, url: @base_url <> path, retry: false]
      |> put_json(body)
      |> Keyword.merge(Application.get_env(:app, :d1_req_options, []))

    case Req.request(options) do
      {:ok, %Req.Response{status: status, body: body}}
      when status in 200..299 and is_map(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: 404}} ->
        {:error, :not_found}

      {:ok, %Req.Response{status: status}} ->
        Logger.error("D1 gateway returned HTTP #{status} for #{method} #{path}")
        {:error, {:gateway_status, status}}

      {:error, reason} ->
        Logger.error("D1 gateway unreachable for #{method} #{path}: #{inspect(reason)}")
        {:error, :gateway_unreachable}
    end
  end

  defp put_json(options, nil), do: options
  defp put_json(options, body), do: Keyword.put(options, :json, body)
end
