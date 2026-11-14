defmodule AppWeb.UserLive.Login do
  use AppWeb, :live_view

  alias App.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm space-y-4">
        <div class="text-center">
          <.header>
            <p>Log in</p>
            <:subtitle>
              <%= if @current_scope do %>
                You need to reauthenticate to perform sensitive actions on your account.
              <% else %>
                Don't have an account? <.link
                  navigate={~p"/users/register"}
                  class="font-semibold text-brand hover:underline"
                  phx-no-format
                >Sign up</.link> for an account now.
              <% end %>
            </:subtitle>
          </.header>
        </div>

        <div :if={local_mail_adapter?()} class="alert alert-info">
          <.icon name="hero-information-circle" class="size-6 shrink-0" />
          <div>
            <p>You are running the local mail adapter.</p>
            <p>
              To see sent emails, visit <.link href="/dev/mailbox" class="underline">the mailbox page</.link>.
            </p>
          </div>
        </div>

        <div :if={!@email_available?} class="alert alert-info" id="email_unavailable">
          <.icon name="hero-information-circle" class="size-6 shrink-0" />
          <div>
            <p>Logging in by email link isn't available yet.</p>
            <p>Use your password below — that is how accounts are registered.</p>
          </div>
        </div>

        <.form
          :let={f}
          :if={@email_available?}
          for={@form}
          id="login_form_magic"
          action={~p"/users/log-in"}
          phx-submit="submit_magic"
        >
          <.input
            readonly={!!@current_scope}
            field={f[:email]}
            type="email"
            label="Email"
            autocomplete="username"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />
          <.button class="btn btn-primary w-full">
            Log in with email <span aria-hidden="true">→</span>
          </.button>
        </.form>

        <div :if={@email_available?} class="divider">or</div>

        <.form
          :let={f}
          for={@form}
          id="login_form_password"
          action={~p"/users/log-in"}
          phx-submit="submit_password"
          phx-trigger-action={@trigger_submit}
        >
          <.input
            readonly={!!@current_scope}
            field={f[:email]}
            type="email"
            label="Email"
            autocomplete="username"
            spellcheck="false"
            required
          />
          <.input
            field={@form[:password]}
            type="password"
            label="Password"
            autocomplete="current-password"
            spellcheck="false"
          />
          <.button class="btn btn-primary w-full" name={@form[:remember_me].name} value="true">
            Log in and stay logged in <span aria-hidden="true">→</span>
          </.button>
          <.button class="btn btn-primary btn-soft w-full mt-2">
            Log in only this time
          </.button>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    email =
      Phoenix.Flash.get(socket.assigns.flash, :email) ||
        get_in(socket.assigns, [:current_scope, Access.key(:user), Access.key(:email)])

    form = to_form(%{"email" => email}, as: "user")

    socket =
      assign(socket,
        form: form,
        trigger_submit: false,
        email_available?: Accounts.email_delivery_available?()
      )

    {:ok, socket}
  end

  @impl true
  def handle_event("submit_password", _params, socket) do
    {:noreply, assign(socket, :trigger_submit, true)}
  end

  def handle_event("submit_magic", %{"user" => %{"email" => email}}, socket) do
    if Accounts.email_delivery_available?() do
      if user = Accounts.get_user_by_email(email) do
        Accounts.deliver_login_instructions(
          user,
          &url(~p"/users/log-in/#{&1}")
        )
      end

      # Deliberately the same answer either way, so the form cannot be used to
      # discover which addresses are registered.
      info =
        "If your email is in our system, you will receive instructions for logging in shortly."

      {:noreply,
       socket
       |> put_flash(:info, info)
       |> push_navigate(to: ~p"/users/log-in")}
    else
      {:noreply,
       put_flash(
         socket,
         :error,
         "Logging in by email link isn't available yet. Use your password instead."
       )}
    end
  end

  defp local_mail_adapter? do
    Application.get_env(:app, App.Mailer)[:adapter] == Swoosh.Adapters.Local
  end
end
