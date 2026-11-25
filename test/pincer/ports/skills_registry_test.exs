defmodule Pincer.Ports.SkillsRegistryTest do
  use ExUnit.Case, async: true

  alias Pincer.Ports.SkillsRegistry

  defmodule RegistryStub do
    @behaviour PincerPorts.SkillsRegistry

    @impl true
    def list_skills(opts), do: {:ok, [Keyword.fetch!(opts, :skill)]}

    @impl true
    def fetch_skill(id, opts) do
      case Keyword.fetch!(opts, :skill) do
        %{id: ^id} = skill -> {:ok, skill}
        _skill -> {:error, :not_found}
      end
    end
  end

  test "the root port delegates to the selected module and passes through its results" do
    skill = %{id: "stub"}
    opts = [skill: skill]

    assert {:ok, [^skill]} = SkillsRegistry.list_skills(RegistryStub, opts)
    assert {:ok, ^skill} = SkillsRegistry.fetch_skill(RegistryStub, "stub", opts)
    assert {:error, :not_found} = SkillsRegistry.fetch_skill(RegistryStub, "missing", opts)
  end
end
