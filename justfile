# Local commands for this repo. `just` with no arguments lists them.
#
# There are three ways to run this app locally, and they are good at different
# things — picking the wrong one wastes an afternoon:
#
#   just dev         Native Phoenix. Full features, including a real database:
#                    App.D1.LocalGateway serves the Worker's D1 contract from
#                    SQLite on :4100. Fastest loop; use this for app work.
#
#   just worker-dev  The real Worker and the real `d1.internal` / `mail.internal`
#                    intercepts, via `wrangler dev`. Needs Docker. Use this when
#                    changing anything in src/index.ts, because it is the only
#                    local mode that exercises the gateways themselves.
#
#   just image-run   The production image on its own. NO DATABASE: the release
#                    compiles `http://d1.internal` in, and nothing serves that
#                    hostname outside a Worker. /tasks shows a setup notice,
#                    /chat runs ephemeral, and registering an account fails.
#                    Use it to check the release builds and boots — which is
#                    the thing that breaks on Apple Silicon — not to use the app.

set shell := ["bash", "-uc"]

app_dir := "app"
image := "phoenix-cf-container:local"
port := "4000"
worker := "phoenix-cf-container"

# List available commands.
default:
    @just --list --unsorted

# ---------------------------------------------------------------- native (mac)

# Install dependencies and build assets (skips the Postgres-only ecto.setup).
setup:
    cd {{app_dir}} && mix deps.get && mix assets.setup && mix assets.build

# Run on http://localhost:4000, with persistence through the local D1 gateway.
dev:
    cd {{app_dir}} && mix phx.server

# Same, with an IEx shell attached.
iex:
    cd {{app_dir}} && iex -S mix phx.server

# Delete the local D1 database. Migrations re-apply on the next boot.
reset-db:
    rm -f {{app_dir}}/priv/d1_local.sqlite3

# Run the test suite. Extra arguments are passed to mix test.
test *args:
    cd {{app_dir}} && mix test {{args}}

# compile --warnings-as-errors, deps.unlock --unused, format, test.
precommit:
    cd {{app_dir}} && mix precommit

# Format Elixir and typecheck the Worker.
fmt:
    cd {{app_dir}} && mix format
    pnpm typecheck

# ---------------------------------------------------------------------- docker

# Build the production image for your own architecture (a few minutes).
image-build:
    docker build -t {{image}} .

# Run the production image on :4000 — no database in this mode, see the header.
image-run:
    docker run --rm -it -p {{port}}:4000 \
      -e SECRET_KEY_BASE="$(openssl rand -base64 48)" \
      -e PHX_HOST=localhost \
      -e PORT=4000 \
      {{image}}

# A shell inside the image, for looking at the release.
image-shell:
    docker run --rm -it --entrypoint sh {{image}}

# Is the running container answering?
image-health:
    curl -fsS http://localhost:{{port}}/health && echo

# ---------------------------------------------------------------------- worker

# The real Worker, DO and gateway intercepts (needs Docker and .dev.vars).
worker-dev:
    pnpm exec wrangler dev

# Live logs from the deployed Worker. The most useful debugging command here.
tail:
    pnpm exec wrangler tail {{worker}} --format json

# Apply pending D1 migrations locally.
migrate-local:
    pnpm exec wrangler d1 migrations apply DB --local

# Post-deploy smoke test: handshake, channel join, broadcast, form redirect.
smoke url:
    pnpm ws:smoke {{url}}
