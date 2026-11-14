defmodule AppWeb.UserLive.RegistrationTest do
  use AppWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import App.AccountsFixtures
  import Swoosh.TestAssertions

  setup :stub_d1_sqlite!

  describe "Registration page" do
    test "renders registration page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/register")

      assert html =~ "Register"
      assert html =~ "Log in"
    end

    test "redirects if already logged in", %{conn: conn} do
      result =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/users/register")
        |> follow_redirect(conn, ~p"/")

      assert {:ok, _conn} = result
    end

    test "renders errors for invalid data", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      result =
        lv
        |> element("#registration_form")
        |> render_change(user: %{"email" => "with spaces"})

      assert result =~ "Register"
      assert result =~ "must have the @ sign and no spaces"
    end
  end

  describe "register user" do
    test "creates an account and logs in, sending no email", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      email = unique_user_email()
      form = form(lv, "#registration_form", user: valid_user_attributes(email: email))
      render_submit(form)

      # The LiveView cannot write the session, so the form posts itself to the
      # session controller; see AppWeb.UserLive.Registration.
      conn = follow_trigger_action(form, conn)

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Account created successfully!"
      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/"

      response = conn |> get(~p"/") |> html_response(200)
      assert response =~ email
      assert response =~ ~p"/users/log-out"

      # Registration is usable with no mail provider configured at all.
      assert_no_email_sent()
    end

    test "registers an account that still needs confirming", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      email = unique_user_email()

      lv
      |> form("#registration_form", user: valid_user_attributes(email: email))
      |> render_submit()

      refute App.Accounts.get_user_by_email(email).confirmed_at
    end

    test "renders errors for a mismatched password confirmation", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      result =
        lv
        |> form("#registration_form",
          user: %{
            "email" => unique_user_email(),
            "password" => valid_user_password(),
            "password_confirmation" => "something else"
          }
        )
        |> render_submit()

      assert result =~ "does not match password"
    end

    test "renders errors for a too-short password", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      result =
        lv
        |> element("#registration_form")
        |> render_change(user: %{"email" => unique_user_email(), "password" => "short"})

      assert result =~ "should be at least 12 character(s)"
    end

    test "renders errors for duplicated email", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      user = user_fixture(%{email: "test@email.com"})

      result =
        lv
        |> form("#registration_form", user: valid_user_attributes(email: user.email))
        |> render_submit()

      assert result =~ "has already been taken"
    end
  end

  describe "registration navigation" do
    test "redirects to login page when the Log in button is clicked", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      {:ok, _login_live, login_html} =
        lv
        |> element("main a", "Log in")
        |> render_click()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert login_html =~ "Log in"
    end
  end
end
