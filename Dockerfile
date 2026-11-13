# ---- Build Stage ----
FROM elixir:1.20.5-alpine AS build

# Work around a QEMU bug that crashes the BEAM when wrangler cross-builds the
# linux/amd64 image on an arm64 host (kernel "nouser" crash in mix/erl).
# Build-time only — the deployed container runs on native amd64.
ENV ERL_FLAGS="+JMsingle true"

# Install build dependencies (git needed for heroicons GitHub dep)
RUN apk add --no-cache build-base git

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod

# Install and compile dependencies
COPY app/mix.exs app/mix.lock ./
RUN mix deps.get
RUN mix deps.compile

# Copy application source
COPY app/config ./config
COPY app/lib ./lib
COPY app/priv ./priv
COPY app/assets ./assets

# Compile the app (runs :phoenix_live_view compiler which generates colocated hooks JS)
RUN mix compile

# Build static assets (esbuild + tailwind are Elixir-managed, no Node.js needed)
RUN mix assets.setup
RUN mix assets.deploy

# Create the release
RUN mix release --overwrite

# ---- Runtime Stage ----
FROM alpine:3.24

# Runtime dependencies: openssl/ncurses for BEAM, ca-certificates for TLS to external Postgres
RUN apk add --no-cache openssl ncurses-libs libstdc++ ca-certificates tini

WORKDIR /app

# Copy the release from the build stage
COPY --from=build /app/_build/prod/rel/app ./

# Same QEMU workaround as the build stage: without it the BEAM's prim_tty NIF
# fails to load under emulation (arm64 host running the linux/amd64 image) and
# the VM dies with a "nouser" crash on boot. Harmless on native amd64.
ENV ERL_FLAGS="+JMsingle true"

ENV PHX_SERVER=true
EXPOSE 4000

# Run migrations on each start, then start the app
CMD ["tini", "--", "sh", "-c", "./bin/app eval App.Release.migrate && exec ./bin/app start"]
