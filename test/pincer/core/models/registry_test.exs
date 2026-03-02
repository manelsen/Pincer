defmodule Pincer.Core.Models.RegistryTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.Models.Registry

  describe "list_providers/1" do
    test "returns stable provider list sorted by id" do
      registry = %{
        "z_ai_coding" => %{default_model: "glm-4.7"},
        "openrouter" => %{default_model: "openrouter/free"}
      }

      providers = Registry.list_providers(registry)

      assert Enum.map(providers, & &1.id) == ["openrouter", "z_ai_coding"]
      assert Enum.map(providers, & &1.name) == ["Openrouter", "Z Ai Coding"]
    end

    test "uses explicit provider name when present" do
      registry = %{
        "z_ai_coding" => %{name: "Z AI Coding", default_model: "glm-4.7"}
      }

      assert [%{id: "z_ai_coding", name: "Z AI Coding"}] = Registry.list_providers(registry)
    end
  end

  describe "list_models/2" do
    test "merges default_model and models removing duplicates and invalid values" do
      registry = %{
        "z_ai" => %{
          default_model: "glm-4.7",
          models: ["glm-4.7", "glm-4.5", "", nil, "  "]
        }
      }

      assert Registry.list_models("z_ai", registry) == ["glm-4.7", "glm-4.5"]
    end

    test "returns empty list for unknown provider" do
      assert Registry.list_models("missing", %{}) == []
    end
  end

  describe "resolve_model/3" do
    test "resolves existing model id directly" do
      registry = %{
        "z_ai" => %{default_model: "glm-4.7", models: ["glm-4.5"]}
      }

      assert {:ok, "glm-4.5"} = Registry.resolve_model("z_ai", "glm-4.5", registry)
    end

    test "resolves model alias" do
      registry = %{
        "z_ai" => %{
          default_model: "glm-4.7",
          models: ["glm-4.5"],
          model_aliases: %{"default" => "glm-4.7", "fast" => "glm-4.5"}
        }
      }

      assert {:ok, "glm-4.7"} = Registry.resolve_model("z_ai", "default", registry)
      assert {:ok, "glm-4.5"} = Registry.resolve_model("z_ai", "fast", registry)
    end

    test "returns explicit errors for unknown provider/model" do
      registry = %{"z_ai" => %{default_model: "glm-4.7"}}

      assert {:error, :unknown_provider} = Registry.resolve_model("missing", "glm-4.7", registry)
      assert {:error, :unknown_model} = Registry.resolve_model("z_ai", "missing-model", registry)
    end
  end
end
