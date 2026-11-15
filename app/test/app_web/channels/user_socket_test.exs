defmodule AppWeb.UserSocketTest do
  use AppWeb.ChannelCase

  import App.AccountsFixtures

  alias App.Accounts.Scope
  alias AppWeb.UserSocket

  setup :stub_d1_sqlite!

  test "connects anonymously when no token is sent" do
    assert {:ok, socket} = connect(UserSocket, %{})
    assert socket.assigns.current_scope == nil
    assert UserSocket.id(socket) == nil
  end

  test "resolves a signed token to the user's scope and a per-user id" do
    user = user_fixture()

    assert {:ok, socket} =
             connect(UserSocket, %{"user_token" => UserSocket.sign_token(user)})

    assert %Scope{user: %{id: user_id}} = socket.assigns.current_scope
    assert user_id == user.id
    assert UserSocket.id(socket) == "users_sockets:#{user.id}"
  end

  test "refuses a bad token rather than downgrading to anonymous" do
    assert :error = connect(UserSocket, %{"user_token" => "garbage"})
    assert :error = connect(UserSocket, %{"user_token" => 42})
  end

  test "refuses a token whose user is gone" do
    user = user_fixture()
    token = UserSocket.sign_token(%{user | id: user.id + 1000})

    assert :error = connect(UserSocket, %{"user_token" => token})
  end
end
