defmodule AppWeb.Presence do
  @moduledoc """
  Presence tracking for chat rooms.

  Presence is the clearest signal that PubSub fan-out works inside the
  container: open two tabs and each must see the other appear and disappear.

  Because `src/index.ts` routes every request to a single Durable Object
  (`getByName("singleton")`), all sockets land on one BEAM node and no
  clustering is involved. If that routing ever changes, presence and chat
  silently split per instance — this demo is how you would notice.
  """

  use Phoenix.Presence,
    otp_app: :app,
    pubsub_server: App.PubSub
end
