defmodule Pincer.Core.CapabilityDiscovery do
  @moduledoc """
  Core capability catalog used for discovery/reporting.

  The catalog intentionally describes capabilities (not implementation detail)
  and stays provider/channel-agnostic.
  """

  @behaviour Pincer.Core.Ports.CapabilityDiscovery

  @capabilities [
    %{
      id: "C01",
      key: :onboarding,
      name: "Linux-style onboarding",
      owner: :core,
      status: :done,
      summary: "Interactive/non-interactive onboarding via core plan/apply flow."
    },
    %{
      id: "C03",
      key: :menu_governance,
      name: "Command menu governance",
      owner: :core,
      status: :done,
      summary: "Shared policy for command normalization/validation/cap."
    },
    %{
      id: "C04",
      key: :menu_affordance,
      name: "Persistent menu affordance",
      owner: :core,
      status: :partial,
      summary: "Menu UX parity across channels with guided fallback."
    },
    %{
      id: "C06",
      key: :dm_policy,
      name: "DM access policy",
      owner: :core,
      status: :done,
      summary: "Core policy engine for open/allowlist/disabled/pairing."
    },
    %{
      id: "C09",
      key: :model_registry,
      name: "Model registry",
      owner: :core,
      status: :done,
      summary: "Provider/model catalog with alias resolution."
    },
    %{
      id: "C12",
      key: :error_taxonomy,
      name: "Operational error taxonomy",
      owner: :core,
      status: :partial,
      summary: "Classified errors + telemetry for resilient operations."
    },
    %{
      id: "C17",
      key: :streaming_policy,
      name: "Streaming finalization policy",
      owner: :core,
      status: :done,
      summary: "Preview cursor and in-place finalization without duplicates."
    }
  ]

  @impl true
  def list_capabilities(_context \\ %{}) do
    @capabilities
  end

  @impl true
  def find_capability(id, context \\ %{}) do
    wanted = id |> to_string() |> String.upcase()

    case Enum.find(list_capabilities(context), &(&1.id == wanted)) do
      nil -> :error
      capability -> {:ok, capability}
    end
  end
end
