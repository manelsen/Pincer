defmodule Pincer.Core.BindingsTest do
  use ExUnit.Case, async: false

  alias Pincer.Core.Bindings
  alias Pincer.Core.Pairing

  setup do
    Pairing.reset()

    on_exit(fn ->
      Pairing.reset()
    end)

    :ok
  end

  test "principal_ref/3 normalizes external identities" do
    assert Bindings.principal_ref(:telegram, :user, 123) == "telegram:user:123"
    assert Bindings.principal_ref(:discord, :user, "456") == "discord:user:456"
    assert Bindings.conversation_ref(:telegram, :dm, 123) == "telegram:dm:123"
  end

  test "bind/2 and resolve/1 bridge through the pairing persistence layer" do
    principal_ref = Bindings.principal_ref(:telegram, :user, 123)

    assert :ok = Bindings.bind(principal_ref, "a1b2c3")
    assert Bindings.resolve(principal_ref) == "a1b2c3"
  end
end
