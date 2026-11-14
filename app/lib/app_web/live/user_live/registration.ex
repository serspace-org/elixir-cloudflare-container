defmodule AppWeb.UserLive.Registration do
  @moduledoc """
  Registration with an email and a password.

  `mix phx.gen.auth` registers by email alone and mails a magic link to
  finish; this app has no mail provider yet, so a password is collected here
  and the new account is logged in straight away. A LiveView cannot write the
  session, so a successful registration sets `@trigger_submit` and lets the
  browser POST the same form to `AppWeb.UserSessionController`, which logs the
  user in. See the moduledoc of `App.Accounts` for the security consequence
  of registering with a password.
  """
  use AppWeb, :live_view

  alias App.Accounts
  alias App.Accounts.User

  require Logger

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm">
        <div class="text-center">
          <.header>
            Register for an account
            <:subtitle>
              Already registered?
              <.link navigate={~p"/users/log-in"} class="font-semibold text-brand hover:underline">
                Log in
              </.link>
              to your account now.
            </:subtitle>
          </.header>
        </div>

        <.form
          for={@form}
          id="registration_form"
          action={~p"/users/log-in?_action=registered"}
          method="post"
          phx-submit="save"
          phx-change="validate"
          phx-trigger-action={@trigger_submit}
        >
          <.input
            field={@form[:email]}
            type="email"
            label="Email"
            autocomplete="username"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />

          <.input
            field={@form[:password]}
            type="password"
            label="Password"
            autocomplete="new-password"
            spellcheck="false"
            required
          />

          <.input
            field={@form[:password_confirmation]}
            type="password"
            label="Confirm password"
            autocomplete="new-password"
            spellcheck="false"
            required
          />

          <.button phx-disable-with="Creating account..." class="btn btn-primary w-full">
            Create an account
          </.button>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, %{assigns: %{current_scope: %{user: user}}} = socket)
      when not is_nil(user) do
    {:ok, redirect(socket, to: AppWeb.UserAuth.signed_in_path(socket))}
  end

  def mount(_params, _session, socket) do
    changeset = change_registration(%{})

    {:ok, socket |> assign(:trigger_submit, false) |> assign_form(changeset),
     temporary_assigns: [form: nil]}
  end

  @impl true
  def handle_event("save", %{"user" => user_params}, socket) do
    case Accounts.register_user(user_params) do
      {:ok, user} ->
        # The form posts itself to the session controller from here; the
        # password is still in the DOM, and never re-rendered by the server.
        {:noreply,
         socket
         |> assign(:trigger_submit, true)
         |> assign_form(
           Accounts.change_user_registration(user, %{},
             validate_unique: false,
             hash_password: false
           )
         )}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}

      {:error, reason} ->
        Logger.error("registration failed: #{inspect(reason)}")

        {:noreply,
         socket
         |> put_flash(:error, "We could not create your account right now. Please try again.")
         |> assign_form(change_registration(user_params))}
    end
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset = change_registration(user_params)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  # Live validation must not hash the password on every keystroke, nor ask the
  # D1 gateway whether the email is taken.
  defp change_registration(user_params) do
    Accounts.change_user_registration(%User{}, user_params,
      validate_unique: false,
      hash_password: false
    )
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, form: to_form(changeset, as: "user"))
  end
end
