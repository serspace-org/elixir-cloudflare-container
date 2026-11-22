defmodule AppWeb.Router do
  use AppWeb, :router

  import AppWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AppWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", AppWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  # Health check endpoint (used by the Worker for readiness checks)
  scope "/", AppWeb do
    pipe_through :api

    get "/health", PageController, :health
    get "/health/sockets", PageController, :socket_health
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:app, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: AppWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes

  scope "/", AppWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{AppWeb.UserAuth, :require_authenticated}] do
      # Tasks are owned by a user (see `App.Tasks`), so `/tasks` lives behind
      # the `:require_authenticated_user` plug and live session: the plug
      # redirects the initial request to the log-in page and the `on_mount`
      # hook does the same for the socket, which is what guarantees
      # `@current_scope.user` in `AppWeb.TaskLive`.
      live "/tasks", TaskLive, :index

      # Chat is signed-in too, for the same reason: a message now carries the
      # account that sent it (`App.Chat.create_message/3` matches the scope),
      # so the plug guarantees a `@current_scope.user` on the initial request
      # and the `on_mount` hook guarantees it on the socket.
      live "/chat", ChatLive, :index
      live "/chat/:room", ChatLive, :index

      # Owned and shared chat rooms — the management surface for the
      # ownership /chat already carries.
      live "/rooms", RoomLive, :index

      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
    end

    post "/users/update-password", UserSessionController, :update_password

    # Plain (non-LiveView) page driving the raw channel client, so a channel
    # failure can be told apart from a LiveView failure. A controller route,
    # so the `:require_authenticated_user` plug above is what guards it; the
    # socket it opens is authenticated separately, by `AppWeb.UserSocket`.
    get "/probe", PageController, :probe
    get "/probe/:room", PageController, :probe
  end

  scope "/", AppWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{AppWeb.UserAuth, :mount_current_scope}] do
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end
end
