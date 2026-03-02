defmodule Pincer.PortsContractTest do
  use ExUnit.Case, async: true

  test "onboard module declares onboarding port behaviour" do
    behaviours = Pincer.Core.Onboard.module_info(:attributes)[:behaviour] || []
    assert Pincer.Ports.Onboarding in behaviours
  end

  test "ux module declares user menu port behaviour" do
    behaviours = Pincer.Core.UX.module_info(:attributes)[:behaviour] || []
    assert Pincer.Ports.UserMenu in behaviours
  end

  test "capability discovery module declares discovery port behaviour" do
    behaviours = Pincer.Core.CapabilityDiscovery.module_info(:attributes)[:behaviour] || []
    assert Pincer.Ports.CapabilityDiscovery in behaviours
  end
end
