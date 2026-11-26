defmodule Pincer.LLM.FailoverTest do
  use ExUnit.Case, async: false

  alias Pincer.Core.AuthProfiles
  alias Pincer.Core.LLM.CooldownStore
  alias Pincer.LLM.Failover
  alias Pincer.Test.Support.LLMHelpers

  defmodule ProbeAdapter do
    use Pincer.Test.Support.LLMProviderDefaults

    @impl true
    def chat_completion(messages, model, config, tools) do
      send(self(), {:failover_adapter_called, :chat, model, config, tools, messages})
      {:ok, %{"role" => "assistant", "content" => "ok:#{model}"}, nil}
    end

    @impl true
    def stream_completion(messages, model, config, tools) do
      send(self(), {:failover_adapter_called, :stream, model, config, tools, messages})
      {:ok, [%{"choices" => [%{"delta" => %{"content" => "stream:#{model}"}}]}]}
    end
  end

  setup do
    CooldownStore.reset()
    AuthProfiles.reset()
    LLMHelpers.put_system_env!("FAILOVER_TEST_KEY", "failover-secret")

    on_exit(fn ->
      CooldownStore.reset()
      AuthProfiles.reset()
    end)

    :ok
  end

  describe "initial_state/1" do
    test "builds initial failover state and respects pre-supplied :failover_state" do
      registry = %{
        "p1" => %{adapter: ProbeAdapter, default_model: "m1", models: ["m1", "m2"]},
        "p2" => %{adapter: ProbeAdapter, default_model: "x1"}
      }

      state = Failover.initial_state(provider: "p1", model: "m1", registry: registry)
      assert state.current_provider == "p1"
      assert state.current_model == "m1"
      assert state.providers == ["p1", "p2"]

      custom = %{current_provider: "p2", current_model: "x1"}

      assert Failover.initial_state(
               provider: "p1",
               model: "m1",
               registry: registry,
               failover_state: custom
             ) == custom
    end
  end

  describe "resolve_provider/2 and resolve_auth/3" do
    test "routes around cooling-down default provider unless explicitly requested" do
      registry = %{
        "p1" => %{adapter: ProbeAdapter, default_model: "m1"},
        "p2" => %{adapter: ProbeAdapter, default_model: "x1"}
      }

      LLMHelpers.put_default_provider!("p1")
      CooldownStore.cooldown_provider("p1", {:http_error, 503, "down"}, duration_ms: 5_000)

      assert Failover.resolve_provider(registry, []) == "p2"
      assert Failover.resolve_provider(registry, provider: "p1") == "p1"
    end

    test "formats missing credentials and all_profiles_cooling_down errors" do
      System.delete_env("FAILOVER_TEST_KEY")

      assert {:error, {:missing_credentials, "FAILOVER_TEST_KEY"}} =
               Failover.resolve_auth("p1", %{env_key: "FAILOVER_TEST_KEY"}, [])

      assert {:error, {:missing_credentials, "API_KEY"}} =
               Failover.resolve_auth("p1", %{auth_profiles: []}, [])

      System.put_env("FAILOVER_TEST_KEY", "failover-secret")

      AuthProfiles.cooldown_profile("p1", "primary", {:http_error, 401, "bad"},
        duration_ms: 5_000
      )

      assert {:error, :all_profiles_cooling_down} =
               Failover.resolve_auth(
                 "p1",
                 %{auth_profiles: [%{name: "primary", env_key: "FAILOVER_TEST_KEY"}]},
                 []
               )
    end
  end

  describe "dispatch/3" do
    test "simulates mock responses and returns provider_not_found for missing providers" do
      LLMHelpers.put_providers!(%{}, default: "mock")

      assert {:ok, %{"content" => "[MOCK] Hello! Configure your LLM providers."}, nil} =
               Failover.dispatch(:chat_completion, [], [])

      assert {:ok, [%{"choices" => [%{"delta" => %{"content" => "[MOCK STREAM] Hello!"}}]}]} =
               Failover.dispatch(:stream_completion, [], [])

      assert {:error, {:provider_not_found, "ghost"}} =
               Failover.dispatch(:chat_completion, [], provider: "ghost")
    end

    test "resolves auth and dispatches chat and stream requests through RetryEngine" do
      LLMHelpers.put_providers!(
        %{
          "p1" => %{
            adapter: ProbeAdapter,
            env_key: "FAILOVER_TEST_KEY",
            default_model: "m1"
          }
        },
        default: "p1"
      )

      messages = [%{"role" => "user", "content" => "hi"}]

      assert {:ok, %{"content" => "ok:m1"}, nil} =
               Failover.dispatch(:chat_completion, messages, tools: [:t1])

      assert_received {:failover_adapter_called, :chat, "m1", config, [:t1], ^messages}
      assert config[:api_key] == "failover-secret"

      assert {:ok, stream} = Failover.dispatch(:stream_completion, messages, model: "m2")
      assert Enum.count(stream) == 1
      assert_received {:failover_adapter_called, :stream, "m2", _config, [], ^messages}
    end
  end
end
