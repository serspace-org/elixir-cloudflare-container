defmodule App.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  # Referenced through an attribute so :prod never compiles a call to a module
  # that only exists in dev/test (see App.D1.LocalGateway).
  @local_d1 App.D1.LocalGateway

  @impl true
  def start(_type, _args) do
    children =
      [
        AppWeb.Telemetry
      ] ++
        if(System.get_env("DATABASE_URL"), do: [App.Repo], else: []) ++
        local_d1_children() ++
        [
          {DNSCluster, query: Application.get_env(:app, :dns_cluster_query) || :ignore},
          {Phoenix.PubSub, name: App.PubSub},
          AppWeb.Presence,
          # Start a worker by calling: App.Worker.start_link(arg)
          # {App.Worker, arg},
          # Start to serve requests, typically the last entry
          AppWeb.Endpoint
        ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: App.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Local stand-in for the Worker's D1 gateway, so `mix phx.server` has real
  # persistence without Docker. Configured in config/dev.exs; absent in prod,
  # where the Worker serves d1.internal for real.
  defp local_d1_children do
    with opts when is_list(opts) <- Application.get_env(:app, :d1_local_gateway),
         true <- Code.ensure_loaded?(@local_d1) do
      @local_d1.children(opts)
    else
      _other -> []
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    AppWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
