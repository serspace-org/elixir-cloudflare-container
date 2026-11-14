# App

The Phoenix application served inside the Cloudflare container. See the
[repo README](../README.md) for the Worker, Durable Object and deployment story,
and `AGENTS.md` in this directory for the Phoenix/Elixir/LiveView coding rules.

## Running it

```bash
mix setup          # NOTE: includes ecto.setup, which needs Postgres on localhost
mix phx.server     # http://localhost:4000, or: iex -S mix phx.server
```

The app persists through Cloudflare D1 rather than Postgres, so `App.Repo` is only
supervised when `DATABASE_URL` is set. Without Postgres, skip the vestigial Ecto step:

```bash
mix deps.get && mix assets.setup && mix assets.build
mix phx.server
```

## What to look at

| Route | What it is |
| --- | --- |
| `/tasks` | CRUD demo over D1 (`App.Tasks`) |
| `/chat`, `/chat/:room` | chat demo on LiveView's `/live` socket (`AppWeb.ChatLive`) |
| `/probe`, `/probe/:room` | same room over a raw channel on `/socket` (`AppWeb.RoomChannel`) |
| `/health` | readiness probe for the Durable Object — must stay fast and never redirect |
| `/health/sockets` | socket/node diagnostics as JSON |

## Database

There is no Ecto repo for application data. `App.Tasks` and `App.Chat` validate with
embedded schemas and persist through `App.D1`, which speaks HTTP to a gateway:

- in production, the Worker's `D1Gateway` on the virtual host `d1.internal`
- in development, `App.D1.LocalGateway` on `127.0.0.1:4100`, backed by
  `priv/d1_local.sqlite3` and applying `../cloudflare/migrations/*.sql` on boot

So `mix phx.server` has real, restart-surviving persistence without Docker. Delete
`priv/d1_local.sqlite3` to reset it. `mix ecto.*` tasks do not apply to this data.

## Tests

```bash
mix test          # no Postgres needed
mix precommit     # compile --warnings-as-errors + deps.unlock --unused + format + test
```

D1 calls are stubbed with `Req.Test` through `App.D1Stub` (see `config/test.exs`), so
the suite never reaches the network. Channel and LiveView tests run non-async because
the stub is resolved in shared mode — the HTTP call comes from the channel or LiveView
process, not the test process.

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://hexdocs.pm/phoenix/overview.html
* Docs: https://hexdocs.pm/phoenix
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix
