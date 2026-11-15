defmodule App.Mailer.Gateway do
  @moduledoc """
  Swoosh adapter that sends through the Worker's private mail gateway.

  The counterpart of `App.D1`: the container POSTs to `http://mail.internal`,
  a hostname that resolves only inside it, and `MailGateway` in `src/index.ts`
  does the sending with the Worker's `EMAIL` binding. No API token is present
  in the image, and nothing is exposed publicly.

  Configured in `config/runtime.exs` for production when `MAIL_FROM` is set.
  Development keeps `Swoosh.Adapters.Local` and the `/dev/mailbox` preview,
  which is both better to work with and the only option without a Worker.

  The gateway pins the sender itself, so the `from` on the email is advisory;
  it is still set from the same address (see `App.Accounts.UserNotifier`) so
  what the mailbox preview shows in development matches production.

  Only the subset the generated notifier needs is supported: one recipient,
  a subject, a text body, and optionally an HTML body and reply-to. Anything
  else — cc, bcc, attachments, custom headers — is rejected here rather than
  silently dropped, because an account email that half-arrives is worse than
  one that visibly fails.
  """

  use Swoosh.Adapter

  require Logger

  @base_url Application.compile_env(:app, :mail_url, "http://mail.internal")

  @impl Swoosh.Adapter
  def deliver(%Swoosh.Email{} = email, _config) do
    with :ok <- validate_unsupported(email),
         {:ok, to} <- recipient(email),
         {:ok, subject} <- required(email.subject, :subject),
         {:ok, text} <- required(email.text_body, :text_body) do
      send_message(%{
        to: to,
        subject: subject,
        text: text,
        html: email.html_body,
        reply_to: address(email.reply_to)
      })
    end
  end

  ## Message building

  # Swoosh keeps recipients as `{name, address}` tuples.
  defp recipient(%Swoosh.Email{to: [{_name, address}]}) when is_binary(address) do
    {:ok, address}
  end

  defp recipient(%Swoosh.Email{to: to}) do
    {:error, {:unsupported, "exactly one recipient is required, got #{inspect(to)}"}}
  end

  defp validate_unsupported(%Swoosh.Email{} = email) do
    unsupported =
      [cc: email.cc, bcc: email.bcc, attachments: email.attachments, headers: email.headers]
      |> Enum.filter(fn {_field, value} -> value not in [nil, [], %{}] end)
      |> Keyword.keys()

    if unsupported == [] do
      :ok
    else
      {:error, {:unsupported, "the mail gateway does not send #{inspect(unsupported)}"}}
    end
  end

  defp required(value, field) do
    case value do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, {:unsupported, "#{field} is required"}}
    end
  end

  defp address(nil), do: nil
  defp address({_name, address}), do: address
  defp address(address) when is_binary(address), do: address

  ## Transport

  defp send_message(params) do
    options =
      [method: :post, url: @base_url <> "/send", json: params, retry: false]
      |> Keyword.merge(Application.get_env(:app, :mail_req_options, []))

    case Req.request(options) do
      {:ok, %Req.Response{status: status, body: %{"message_id" => id}}}
      when status in 200..299 ->
        {:ok, %{id: id}}

      {:ok, %Req.Response{status: 503}} ->
        # The Worker has no EMAIL binding or no MAIL_FROM. Distinguished from
        # a failed send because it is a deployment state, not a bad message.
        Logger.error("mail gateway reports email sending is not configured")
        {:error, :mailer_not_configured}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.error("mail gateway returned HTTP #{status}: #{inspect(body)}")
        {:error, {:gateway_status, status}}

      {:error, reason} ->
        Logger.error("mail gateway unreachable: #{inspect(reason)}")
        {:error, :gateway_unreachable}
    end
  end
end
