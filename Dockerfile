# ---- Build stage ----
FROM elixir:1.17.2-alpine AS build

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod

COPY app/mix.exs ./
COPY app/lib ./lib
COPY app/config ./config

RUN mix release poc_app --overwrite

# ---- Runtime stage ----
FROM alpine:3.20

RUN apk add --no-cache openssl ncurses-libs

WORKDIR /app
COPY --from=build /app/_build/prod/rel/poc_app ./

EXPOSE 4000

CMD ["./bin/poc_app", "start"]
