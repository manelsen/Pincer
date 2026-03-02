defmodule Pincer.Core.CapabilityDiscoveryTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.CapabilityDiscovery

  test "list_capabilities/1 exposes core capability baseline in stable order" do
    ids =
      CapabilityDiscovery.list_capabilities(%{})
      |> Enum.map(& &1.id)

    assert ids == Enum.sort(ids)
    assert "C01" in ids
    assert "C03" in ids
    assert "C04" in ids
    assert "C06" in ids
    assert "C09" in ids
    assert "C12" in ids
    assert "C17" in ids
  end

  test "find_capability/2 returns capability metadata by id" do
    assert {:ok, capability} = CapabilityDiscovery.find_capability("C01", %{})
    assert capability.id == "C01"
    assert capability.key == :onboarding
    assert capability.owner == :core
  end

  test "find_capability/2 returns :error for unknown id" do
    assert :error = CapabilityDiscovery.find_capability("C99", %{})
  end
end
