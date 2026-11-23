defmodule Pincer.Infra.UUIDTest do
  use ExUnit.Case, async: true

  alias Pincer.Infra.UUID

  test "generates RFC 4122 v4 UUIDs" do
    uuid = UUID.generate()

    assert uuid =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
    assert uuid == String.downcase(uuid)
  end

  test "generates unique values" do
    refute UUID.generate() == UUID.generate()
  end
end
