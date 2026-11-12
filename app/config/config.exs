import Config

# Release configuration
config :poc_app, PocApp.Application,
  port: String.to_integer(System.get_env("PORT", "4000"))

# Logger: minimal console output
config :logger, :console,
  level: :info,
  format: "$time $metadata[$level] $message\n"
