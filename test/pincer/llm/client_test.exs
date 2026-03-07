defmodule Pincer.LLM.ClientTest do
  use ExUnit.Case

  alias Pincer.LLM.Client

  defmodule MockAdapter do
    use Pincer.Test.Support.LLMProviderDefaults

    @impl true
    def chat_completion(messages, model, config, tools) do
      send(self(), {:mock_called, messages, model, config, tools})
      {:ok, %{"role" => "assistant", "content" => "MockAdapter response"}, nil}
    end

    @impl true
    def stream_completion(_messages, _model, _config, _tools) do
      {:ok, [%{"choices" => [%{"delta" => %{"content" => "MockAdapter stream"}}]}]}
    end

    @impl true
    def list_models(config) do
      case Map.get(config, :models) do
        nil -> {:ok, []}
        list -> {:ok, list}
      end
    end

    @impl true
    def transcribe_audio(_path, _model, _config), do: {:ok, "mock transcript"}
  end

  defmodule InvalidStreamAdapter do
    use Pincer.Test.Support.LLMProviderDefaults

    @impl true
    def chat_completion(_messages, _model, _config, _tools) do
      {:ok, %{"role" => "assistant", "content" => "fallback-chat"}, nil}
    end

    @impl true
    def stream_completion(_messages, _model, _config, _tools) do
      {:ok, %Req.Response{status: 400, headers: %{}, body: %{}, trailers: %{}, private: %{}}}
    end

    @impl true
    def list_models(_config), do: {:ok, []}

    @impl true
    def transcribe_audio(_path, _model, _config), do: {:ok, "mock transcript"}
  end

  setup do
    # Save original env
    orig_providers = Application.get_env(:pincer, :llm_providers)
    orig_default = Application.get_env(:pincer, :default_llm_provider)
    orig_llm = Application.get_env(:pincer, :llm)

    # Set test env
    Application.put_env(:pincer, :llm_providers, %{
      "test_provider" => %{
        adapter: MockAdapter,
        env_key: "TEST_API_KEY",
        default_model: "test-model"
      }
    })

    Application.put_env(:pincer, :default_llm_provider, "test_provider")
    Application.delete_env(:pincer, :llm)
    System.put_env("TEST_API_KEY", "fake_key_123")

    on_exit(fn ->
      if orig_providers do
        Application.put_env(:pincer, :llm_providers, orig_providers)
      else
        Application.delete_env(:pincer, :llm_providers)
      end

      if orig_default do
        Application.put_env(:pincer, :default_llm_provider, orig_default)
      else
        Application.delete_env(:pincer, :default_llm_provider)
      end

      if orig_llm do
        Application.put_env(:pincer, :llm, orig_llm)
      else
        Application.delete_env(:pincer, :llm)
      end
    end)

    :ok
  end

  describe "chat_completion/2 routing" do
    test "delegates to default provider when no provider is specified" do
      messages = [%{"role" => "user", "content" => "Hello"}]

      assert {:ok, resp, _usage} = Client.chat_completion(messages)
      assert resp["content"] == "MockAdapter response"

      assert_received {:mock_called, ^messages, "test-model", config, []}
      assert config[:adapter] == MockAdapter
      assert config[:api_key] == "fake_key_123"
    end

    test "delegates to specific provider and model when provided" do
      messages = [%{"role" => "user", "content" => "Hi there"}]

      assert {:ok, resp, _usage} =
               Client.chat_completion(messages, provider: "test_provider", model: "custom-model")

      assert resp["content"] == "MockAdapter response"

      assert_received {:mock_called, ^messages, "custom-model", _config, []}
    end

    test "falls back to mock response for unknown provider" do
      messages = [%{"role" => "user", "content" => "Hi"}]

      assert {:ok, resp, _usage} = Client.chat_completion(messages, provider: "non_existent")
      assert String.contains?(resp["content"], "[MOCK]")
    end
  end

  describe "model registry integration" do
    test "list_providers/0 prioritizes config.yaml llm structure and ignores selector key" do
      Application.put_env(:pincer, :llm, %{
        "provider" => "z_ai",
        "z_ai" => %{"default_model" => "glm-4.7"},
        "openrouter" => %{"default_model" => "openrouter/free"}
      })

      Application.put_env(:pincer, :llm_providers, %{
        "moonshot" => %{adapter: MockAdapter, default_model: "moonshot-v1-auto"}
      })

      providers = Client.list_providers()

      assert Enum.map(providers, & &1.id) == ["moonshot", "openrouter", "z_ai"]
    end

    test "list_models/1 reads model list from config.yaml llm structure when present" do
      Application.put_env(:pincer, :llm, %{
        "provider" => "z_ai",
        "z_ai" => %{
          "default_model" => "glm-4.7",
          "model_list" => ["glm-4.7", "glm-4.5"]
        }
      })

      Application.put_env(:pincer, :llm_providers, %{
        "z_ai" => %{adapter: MockAdapter, default_model: "legacy-model"}
      })

      assert Client.list_models("z_ai") == ["glm-4.7", "glm-4.5"]
    end

    test "list_providers/0 returns stable ids" do
      Application.put_env(:pincer, :llm_providers, %{
        "z_ai" => %{adapter: MockAdapter, default_model: "glm-4.7"},
        "openrouter" => %{adapter: MockAdapter, default_model: "openrouter/free"}
      })

      providers = Client.list_providers()

      assert Enum.map(providers, & &1.id) == ["openrouter", "z_ai"]
    end

    test "list_models/1 deduplicates default and model list" do
      Application.put_env(:pincer, :llm_providers, %{
        "z_ai" => %{
          adapter: MockAdapter,
          default_model: "glm-4.7",
          models: ["glm-4.7", "glm-4.5"]
        }
      })

      assert Client.list_models("z_ai") == ["glm-4.7", "glm-4.5"]
    end

    test "list_models/1 falls back to llm_providers when llm config is unavailable" do
      Application.delete_env(:pincer, :llm)

      Application.put_env(:pincer, :llm_providers, %{
        "z_ai" => %{
          adapter: MockAdapter,
          default_model: "glm-4.7",
          models: ["glm-4.5"]
        }
      })

      assert Client.list_models("z_ai") == ["glm-4.5"]
    end
  end

  describe "streaming hardening" do
    test "falls back to single-shot chat when stream is not consumable" do
      Application.put_env(:pincer, :llm_providers, %{
        "invalid_stream_provider" => %{
          adapter: InvalidStreamAdapter,
          default_model: "test-model"
        }
      })

      Application.put_env(:pincer, :default_llm_provider, "invalid_stream_provider")

      assert {:ok, chunks} = Client.stream_completion([%{"role" => "user", "content" => "oi"}])

      assert Enum.any?(chunks, fn chunk ->
               get_in(chunk, ["choices", Access.at(0), "delta", "content"]) == "fallback-chat"
             end)
    end
  end
end
