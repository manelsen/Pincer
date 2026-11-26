defmodule Pincer.LLM.ClientAuthProfilesTest do
  use ExUnit.Case, async: false

  alias Pincer.Core.AuthProfiles
  alias Pincer.LLM.Client
  alias Pincer.Test.Support.LLMHelpers

  defmodule AuthProfileAdapter do
    use Pincer.Test.Support.LLMProviderDefaults

    @impl true
    def chat_completion(_messages, _model, config, _tools) do
      send(self(), {:auth_profile_adapter_config, config})
      {:ok, %{"role" => "assistant", "content" => "ok"}, nil}
    end

    @impl true
    def stream_completion(_messages, _model, config, _tools) do
      send(self(), {:auth_profile_adapter_stream_config, config})
      {:ok, [%{"choices" => [%{"delta" => %{"content" => "ok"}}]}]}
    end
  end

  setup do
    AuthProfiles.reset()

    LLMHelpers.put_providers!(
      %{
        "auth_provider" => %{
          adapter: AuthProfileAdapter,
          default_model: "auth-model",
          auth_profiles: [
            %{name: "primary", env_key: "TEST_AUTH_PRIMARY"},
            %{name: "backup", env_key: "TEST_AUTH_BACKUP"}
          ]
        }
      },
      default: "auth_provider"
    )

    LLMHelpers.put_system_env!("TEST_AUTH_PRIMARY", "primary-key")
    LLMHelpers.put_system_env!("TEST_AUTH_BACKUP", "backup-key")

    on_exit(fn ->
      AuthProfiles.reset()
    end)

    :ok
  end

  test "uses primary auth profile by default" do
    assert {:ok, %{"content" => "ok"}, _usage} = Client.chat_completion([])

    assert_received {:auth_profile_adapter_config, config}
    assert config[:api_key] == "primary-key"
    assert config[:auth_profile] == "primary"
  end

  test "routes to backup auth profile when primary is cooling down" do
    assert :ok =
             AuthProfiles.cooldown_profile(
               "auth_provider",
               "primary",
               {:http_error, 401, "unauth"},
               duration_ms: 60_000
             )

    assert AuthProfiles.cooling_down?("auth_provider", "primary")

    assert {:ok, %{"content" => "ok"}, _usage} = Client.chat_completion([])

    assert_received {:auth_profile_adapter_config, config}
    assert config[:api_key] == "backup-key"
    assert config[:auth_profile] == "backup"
  end

  test "returns error when no auth profile has credentials" do
    System.delete_env("TEST_AUTH_PRIMARY")
    System.delete_env("TEST_AUTH_BACKUP")

    assert {:error, {:missing_credentials, _}} = Client.chat_completion([])
  end

  test "keeps backward compatibility when provider has no auth chain" do
    LLMHelpers.put_providers!(
      %{
        "legacy_provider" => %{
          adapter: AuthProfileAdapter,
          default_model: "legacy-model"
        }
      },
      default: "legacy_provider"
    )

    assert {:ok, %{"content" => "ok"}, _usage} = Client.chat_completion([])
    assert_received {:auth_profile_adapter_config, config}
    refute Map.has_key?(config, :auth_profile)
  end
end
