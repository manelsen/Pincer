defmodule Pincer.LLM.ModelCacheTest do
  use ExUnit.Case, async: false

  alias Pincer.LLM.ModelCache
  alias Pincer.Test.Support.LLMHelpers

  defmodule CountingModelsAdapter do
    use Pincer.Test.Support.LLMProviderDefaults

    @impl true
    def chat_completion(_messages, _model, _config, _tools), do: {:ok, %{}, nil}

    @impl true
    def stream_completion(_messages, _model, _config, _tools), do: {:ok, []}

    @impl true
    def list_models(config) do
      send(self(), {:adapter_list_models_called, config[:api_key], config[:tag]})

      case Map.get(config, :models_response) do
        nil -> {:ok, []}
        result -> result
      end
    end
  end

  setup do
    LLMHelpers.put_app_env!(:llm_providers, Application.get_env(:pincer, :llm_providers))
    LLMHelpers.put_app_env!(:llm, Application.get_env(:pincer, :llm))
    old_api_key = System.get_env("MODEL_CACHE_TEST_KEY")

    clear_cache_table()

    on_exit(fn ->
      clear_cache_table()

      if old_api_key do
        System.put_env("MODEL_CACHE_TEST_KEY", old_api_key)
      else
        System.delete_env("MODEL_CACHE_TEST_KEY")
      end
    end)

    :ok
  end

  describe "list_providers/0 and provider_config/1" do
    test "merges :llm over :llm_providers while ignoring selector and invalid entries" do
      LLMHelpers.put_providers!(%{
        "moonshot" => %{adapter: CountingModelsAdapter, default_model: "moonshot-v1"},
        "z_ai" => %{adapter: CountingModelsAdapter, default_model: "legacy"}
      })

      Application.put_env(:pincer, :llm, %{
        "provider" => "z_ai",
        "" => %{"default_model" => "ignored"},
        "broken" => "not-a-map",
        :z_ai => %{"default_model" => "glm-4.7"}
      })

      registry = ModelCache.model_selection_registry()
      assert Map.has_key?(registry, "moonshot")
      assert Map.has_key?(registry, "z_ai")
      refute Map.has_key?(registry, "provider")
      refute Map.has_key?(registry, "")
      refute Map.has_key?(registry, "broken")
      assert registry["z_ai"]["default_model"] == "glm-4.7"

      assert Enum.map(ModelCache.list_providers(), & &1.id) == ["moonshot", "z_ai"]
      assert ModelCache.provider_config("moonshot")[:default_model] == "moonshot-v1"
      assert ModelCache.provider_config("missing") == nil
    end
  end

  describe "list_models/1 and ETS 1h TTL caching" do
    test "caches adapter models in :pincer_llm_cache and avoids duplicate adapter calls" do
      System.put_env("MODEL_CACHE_TEST_KEY", "cache-key-1")

      LLMHelpers.put_providers!(%{
        "cached_provider" => %{
          adapter: CountingModelsAdapter,
          env_key: "MODEL_CACHE_TEST_KEY",
          default_model: "fallback-model",
          tag: :v1,
          models_response: {:ok, ["dynamic-a", "dynamic-b"]}
        }
      })

      Application.delete_env(:pincer, :llm)

      assert ModelCache.list_models("cached_provider") == ["dynamic-a", "dynamic-b"]
      assert_received {:adapter_list_models_called, "cache-key-1", :v1}

      assert ModelCache.list_models("cached_provider") == ["dynamic-a", "dynamic-b"]
      refute_received {:adapter_list_models_called, _, _}

      fingerprint = ModelCache.config_fingerprint("cached_provider")

      assert [{_, ["dynamic-a", "dynamic-b"], expiry}] =
               :ets.lookup(:pincer_llm_cache, {:models, "cached_provider", fingerprint})

      assert expiry > System.system_time(:second)
    end

    test "re-fetches when ETS cache entry has expired" do
      System.put_env("MODEL_CACHE_TEST_KEY", "cache-key-2")

      LLMHelpers.put_providers!(%{
        "expired_provider" => %{
          adapter: CountingModelsAdapter,
          env_key: "MODEL_CACHE_TEST_KEY",
          default_model: "fallback-model",
          tag: :v1,
          models_response: {:ok, ["fresh-model"]}
        }
      })

      Application.delete_env(:pincer, :llm)
      assert ModelCache.list_models("expired_provider") == ["fresh-model"]
      assert_received {:adapter_list_models_called, "cache-key-2", :v1}

      fingerprint = ModelCache.config_fingerprint("expired_provider")
      key = {:models, "expired_provider", fingerprint}
      :ets.insert(:pincer_llm_cache, {key, ["stale-model"], System.system_time(:second) - 10})

      assert ModelCache.list_models("expired_provider") == ["fresh-model"]
      assert_received {:adapter_list_models_called, "cache-key-2", :v1}
    end

    test "invalidates cache via config_fingerprint/1 when configuration changes" do
      Application.delete_env(:pincer, :llm)

      LLMHelpers.put_providers!(%{
        "fp_provider" => %{
          adapter: CountingModelsAdapter,
          default_model: "m1",
          models: ["m1"]
        }
      })

      fp1 = ModelCache.config_fingerprint("fp_provider")
      assert ModelCache.list_models("fp_provider") == ["m1"]

      LLMHelpers.put_providers!(%{
        "fp_provider" => %{
          adapter: CountingModelsAdapter,
          default_model: "m2",
          models: ["m2"]
        }
      })

      fp2 = ModelCache.config_fingerprint("fp_provider")
      refute fp1 == fp2
      assert ModelCache.list_models("fp_provider") == ["m2"]
    end

    test "falls back to ModelRegistry for mock, missing config, or auth failure" do
      Application.delete_env(:pincer, :llm)
      System.delete_env("MODEL_CACHE_TEST_KEY")

      LLMHelpers.put_providers!(%{
        "mock" => %{default_model: "mock-1", models: ["mock-1", "mock-2"]},
        "no_creds" => %{
          adapter: CountingModelsAdapter,
          env_key: "MODEL_CACHE_TEST_KEY",
          default_model: "fallback-1",
          models: ["fallback-2"]
        }
      })

      assert ModelCache.list_models("mock") == ["mock-1", "mock-2"]
      assert ModelCache.list_models("no_creds") == ["fallback-1", "fallback-2"]
      assert ModelCache.list_models("unknown") == []
      refute_received {:adapter_list_models_called, _, _}
    end
  end

  defp clear_cache_table do
    if :ets.whereis(:pincer_llm_cache) != :undefined do
      :ets.delete_all_objects(:pincer_llm_cache)
    end
  end
end
