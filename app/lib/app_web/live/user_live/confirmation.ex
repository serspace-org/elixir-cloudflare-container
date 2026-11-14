defmodule AppWeb.UserLive.Confirmation do
  use AppWeb, :live_view

  alias App.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm">
        <div class="text-center">
          <.header>Welcome {@user.email}</.header>
        </div>

        <div :if={@needs_password_login?} class="alert alert-info mt-8" id="confirm_needs_login">
          <.icon name="hero-information-circle" class="size-6 shrink-0" />
          <div>
            <p>This account has a password, so confirming it needs that password.</p>
            <p>
              <.link navigate={~p"/users/log-in"} class="underline">Log in</.link>
              and open this link again to finish confirming.
            </p>
          </div>
        </div>

        <.form
          :if={!@user.confirmed_at and not @needs_password_login?}
          for={@form}
          id="confirmation_form"
          phx-mounted={JS.focus_first()}
          phx-submit="submit"
          action={~p"/users/log-in?_action=confirmed"}
          phx-trigger-action={@trigger_submit}
        >
          <input type="hidden" name={@form[:token].name} value={@form[:token].value} />
          <.button
            name={@form[:remember_me].name}
            value="true"
            phx-disable-with="Confirming..."
            class="btn btn-primary w-full"
          >
            Confirm and stay logged in
          </.button>
          <.button phx-disable-with="Confirming..." class="btn btn-primary btn-soft w-full mt-2">
            Confirm and log in only this time
          </.button>
        </.form>

        <.form
          :if={@user.confirmed_at}
          for={@form}
          id="login_form"
          phx-submit="submit"
          phx-mounted={JS.focus_first()}
          action={~p"/users/log-in"}
          phx-trigger-action={@trigger_submit}
        >
          <input type="hidden" name={@form[:token].name} value={@form[:token].value} />
          <%= if @current_scope do %>
            <.button phx-disable-with="Logging in..." class="btn btn-primary w-full">
              Log in
            </.button>
          <% else %>
            <.button
              name={@form[:remember_me].name}
              value="true"
              phx-disable-with="Logging in..."
              class="btn btn-primary w-full"
            >
              Keep me logged in on this device
            </.button>
            <.button phx-disable-with="Logging in..." class="btn btn-primary btn-soft w-full mt-2">
              Log me in only this time
            </.button>
          <% end %>
        </.form>

        <p
          :if={!@user.confirmed_at and is_nil(@user.hashed_password)}
          class="alert alert-outline mt-8"
        >
          Tip: If you prefer passwords, you can enable them in the user settings.
        </p>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    if user = Accounts.get_user_by_magic_link_token(token) do
      form = to_form(%{"token" => token}, as: "user")

      socket =
        assign(socket,
          user: user,
          form: form,
          trigger_submit: false,
          needs_password_login?: needs_password_login?(socket.assigns.current_scope, user)
        )

      {:ok, socket, temporary_assigns: [form: nil]}
    else
      {:ok,
       socket
       |> put_flash(:error, "Magic link is invalid or it has expired.")
       |> push_navigate(to: ~p"/users/log-in")}
    end
  end

  @impl true
  def handle_event("submit", %{"user" => params}, socket) do
    {:noreply, assign(socket, form: to_form(params, as: "user"), trigger_submit: true)}
  end

  # Mirrors the check in `App.Accounts.login_user_by_magic_link/2`: an
  # unconfirmed account with a password can only be confirmed by a requester
  # already logged in as that user, so don't offer a button that would fail.
  defp needs_password_login?(current_scope, user) do
    is_nil(user.confirmed_at) and not is_nil(user.hashed_password) and
      not logged_in_as?(current_scope, user)
  end

  defp logged_in_as?(%{user: %{id: id}}, %{id: id}), do: true
  defp logged_in_as?(_current_scope, _user), do: false
end
