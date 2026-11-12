# ---- Build stage ----
FROM elixir:1.18-alpine AS build

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod

# Install dependencies first for better layer caching
COPY app/mix.exs app/mix.lock* ./
RUN mix deps.get --only prod

# Copy application code
COPY app/lib ./lib
COPY app/config ./config

# Compile with --no-parallel to avoid module identity race condition
# that triggers under QEMU emulation (AMD64 on Apple Silicon)
RUN mix compile --no-parallel

# Build the release (compilation already done above)
RUN mix release poc_app --overwrite

# ---- Runtime stage ----
FROM alpine:3.20

RUN apk add --no-cache openssl ncurses-libs

WORKDIR /app
COPY --from=build /app/_build/prod/rel/poc_app ./

EXPOSE 4000

CMD ["./bin/poc_app", "start"]
