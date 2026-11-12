# ---- Build + Runtime (single stage) ----
FROM elixir:1.17.2-alpine

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod

COPY app/mix.exs ./
COPY app/lib ./lib
COPY app/config ./config

# Compile the app (zero external deps, just our 2 files)
RUN mix compile

EXPOSE 4000

CMD ["mix", "run", "--no-halt"]
