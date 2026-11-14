defmodule AppWeb.ChannelCase do
  @moduledoc """
  Test case for channel tests.

  No Ecto sandbox here: chat state lives in Cloudflare D1, reached over HTTP
  through `App.D1`. Stub those calls with the `App.D1Stub` helpers, which are
  imported for you.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint AppWeb.Endpoint

      import Phoenix.ChannelTest
      import App.D1Stub
    end
  end

  setup tags do
    # Shared mode so the channel process can see the test's stub.
    Req.Test.set_req_test_from_context(tags)
    :ok
  end
end
