ExUnit.start()

# App.Repo is vestigial: App.Application only supervises it when DATABASE_URL
# is set (the app persists through Cloudflare D1). Only configure the Ecto
# sandbox when the repo is actually running, so the suite runs without
# Postgres.
if Process.whereis(App.Repo) do
  Ecto.Adapters.SQL.Sandbox.mode(App.Repo, :manual)
end
