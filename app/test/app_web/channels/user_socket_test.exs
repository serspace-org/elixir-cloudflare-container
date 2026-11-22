defmodule AppWeb.UserSocketTest do
  @moduledoc """
  `/socket` requires a logged-in account. It cannot read the session, so it
  authenticates with the token the root layout mints — these tests are the
  only place that whole handshake is exercised.
  """

  # Not async: the stub is resolved in shared mode, and the gateway call
  # resolving the account comes from the socket process. See App.D1Stub.
  use AppWeb.ChannelCase, async: false

  import App.AccountsFixtures

  alias App.Accounts.Scope
  alias AppWeb.UserAuth
  alias AppWeb.UserSocket

  setup :stub_d1_sqlite!

  test "connects with a token minted for a logged-in scope" do
    user = user_fixture()
    token = UserAuth.user_socket_token(Scope.for_user(user))

    assert {:ok, socket} = connect(UserSocket, %{"user_token" => token})
    assert socket.assigns.scope.user.id == user.id
    assert socket.assigns.nickname == App.Chat.sender_name(Scope.for_user(user))
    assert UserSocket.id(socket) == UserAuth.user_socket_topic(user.id)
  end

  test "refuses a connection with no token" do
    assert :error = connect(UserSocket, %{})
  end

  test "refuses a token this app did not sign" do
    assert :error = connect(UserSocket, %{"user_token" => "not-a-token"})
  end

  test "refuses a token whose account is gone" do
    # A signed token is only a claim about an id; the account behind it still
    # has to exist, or a deleted user keeps a working socket.
    token = Phoenix.Token.sign(AppWeb.Endpoint, "user socket", 123_456_789)

    assert :error = connect(UserSocket, %{"user_token" => token})
  end

  test "does not mint a token for a scope with no user" do
    refute UserAuth.user_socket_token(nil)
  end
end
