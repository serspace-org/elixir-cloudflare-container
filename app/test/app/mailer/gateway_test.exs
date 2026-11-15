defmodule App.Mailer.GatewayTest do
  @moduledoc """
  The adapter's half of the mail gateway's HTTP contract. The Worker's half is
  `MailGateway` in `src/index.ts`; when you change one, change the other, the
  same rule the D1 gateway follows.
  """

  # async: false because the last test changes application env, which is global.
  use ExUnit.Case, async: false

  import Swoosh.Email

  alias App.Mailer.Gateway

  setup tags do
    Req.Test.set_req_test_from_context(tags)
    :ok
  end

  defp email(overrides \\ []) do
    base =
      new()
      |> to("ada@example.com")
      |> from({"App", "auth@mail.example.com"})
      |> subject("Log in instructions")
      |> text_body("http://localhost/users/log-in/token")

    Enum.reduce(overrides, base, fn {key, value}, acc -> Map.put(acc, key, value) end)
  end

  defp stub(fun), do: Req.Test.stub(Gateway, fun)

  test "posts the message to the gateway and returns its id" do
    stub(fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/send"

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      params = Jason.decode!(body)

      assert params["to"] == "ada@example.com"
      assert params["subject"] == "Log in instructions"
      assert params["text"] =~ "/users/log-in/token"
      # The gateway pins the sender itself, so there is nothing to send.
      refute Map.has_key?(params, "from")

      conn |> Plug.Conn.put_status(202) |> Req.Test.json(%{"message_id" => "abc123"})
    end)

    assert {:ok, %{id: "abc123"}} = Gateway.deliver(email(), [])
  end

  test "reports the gateway having no mailer configured" do
    stub(fn conn ->
      conn
      |> Plug.Conn.put_status(503)
      |> Req.Test.json(%{"error" => "email sending not configured"})
    end)

    # Distinct from a failed send: this is a deployment state, and
    # App.Accounts' guard is what should normally prevent reaching it.
    assert Gateway.deliver(email(), []) == {:error, :mailer_not_configured}
  end

  test "reports a rejected send rather than claiming delivery" do
    stub(fn conn ->
      conn |> Plug.Conn.put_status(502) |> Req.Test.json(%{"error" => "send failed"})
    end)

    assert Gateway.deliver(email(), []) == {:error, {:gateway_status, 502}}
  end

  test "reports an unreachable gateway" do
    stub(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

    assert Gateway.deliver(email(), []) == {:error, :gateway_unreachable}
  end

  test "refuses what the gateway cannot send, instead of dropping it silently" do
    stub(fn _conn -> flunk("should not have reached the gateway") end)

    assert {:error, {:unsupported, _}} = Gateway.deliver(email(cc: [{"", "b@e.com"}]), [])
    assert {:error, {:unsupported, _}} = Gateway.deliver(email(bcc: [{"", "b@e.com"}]), [])

    assert {:error, {:unsupported, _}} =
             Gateway.deliver(email(to: [{"", "a@e.com"}, {"", "b@e.com"}]), [])

    assert {:error, {:unsupported, _}} = Gateway.deliver(email(text_body: nil), [])
    assert {:error, {:unsupported, _}} = Gateway.deliver(email(subject: ""), [])
  end

  test "passes an HTML body and reply-to through when present" do
    stub(fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      params = Jason.decode!(body)

      assert params["html"] == "<p>hi</p>"
      assert params["reply_to"] == "support@example.com"

      conn |> Plug.Conn.put_status(202) |> Req.Test.json(%{"message_id" => "x"})
    end)

    assert {:ok, _metadata} =
             email()
             |> html_body("<p>hi</p>")
             |> reply_to("support@example.com")
             |> Gateway.deliver([])
  end

  test "the notifier's from address comes from config" do
    previous = Application.get_env(:app, :mail_from)
    Application.put_env(:app, :mail_from, {"App", "auth@mail.example.com"})

    # Restore by deleting when it was unset: putting `nil` back is not the same
    # thing, and `from(nil)` raises in every other test that sends an email.
    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:app, :mail_from)
      else
        Application.put_env(:app, :mail_from, previous)
      end
    end)

    user = %App.Accounts.User{email: "ada@example.com"}

    {:ok, sent} =
      App.Accounts.UserNotifier.deliver_login_instructions(user, "http://localhost/x")

    assert sent.from == {"App", "auth@mail.example.com"}
  end
end
