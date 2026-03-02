defmodule Pincer.Core.AuthProfilesTest do
  use ExUnit.Case, async: false

  alias Pincer.Core.AuthProfiles

  setup do
    AuthProfiles.reset()

    on_exit(fn ->
      AuthProfiles.reset()
    end)

    :ok
  end

  describe "resolve/3" do
    test "uses profile precedence order by default" do
      provider_config = %{
        auth_profiles: [
          %{name: "primary", env_key: "PRIMARY_KEY"},
          %{name: "backup", env_key: "BACKUP_KEY"}
        ]
      }

      assert {:ok, selection} =
               AuthProfiles.resolve("provider_a", provider_config,
                 env_fetcher: fn
                   "PRIMARY_KEY" -> "pk-primary"
                   "BACKUP_KEY" -> "pk-backup"
                   _ -> nil
                 end
               )

      assert selection.profile == "primary"
      assert selection.api_key == "pk-primary"
    end

    test "returns error when all credentials are missing" do
      provider_config = %{
        auth_profiles: [
          %{name: "primary", env_key: "PRIMARY_KEY"},
          %{name: "backup", env_key: "BACKUP_KEY"}
        ]
      }

      assert {:error, :missing_credentials} =
               AuthProfiles.resolve("provider_a", provider_config, env_fetcher: fn _ -> nil end)
    end

    test "keeps legacy provider behavior when auth chain is not declared" do
      provider_config = %{adapter: :mock_adapter, default_model: "x"}

      assert {:ok, selection} =
               AuthProfiles.resolve("provider_a", provider_config, env_fetcher: fn _ -> nil end)

      assert selection.profile == nil
      assert selection.api_key == nil
      assert selection.config == provider_config
    end

    test "returns missing credentials when auth chain is declared but unusable" do
      provider_config = %{auth_profiles: [%{name: "primary"}]}

      assert {:error, :missing_credentials} =
               AuthProfiles.resolve("provider_a", provider_config, env_fetcher: fn _ -> nil end)
    end

    test "skips profile in cooldown and rotates to next credential" do
      provider_config = %{
        auth_profiles: [
          %{name: "primary", env_key: "PRIMARY_KEY"},
          %{name: "backup", env_key: "BACKUP_KEY"}
        ]
      }

      assert :ok =
               AuthProfiles.cooldown_profile(
                 "provider_a",
                 "primary",
                 {:http_error, 401, "unauth"},
                 duration_ms: 60_000
               )

      assert {:ok, selection} =
               AuthProfiles.resolve("provider_a", provider_config,
                 env_fetcher: fn
                   "PRIMARY_KEY" -> "pk-primary"
                   "BACKUP_KEY" -> "pk-backup"
                   _ -> nil
                 end
               )

      assert selection.profile == "backup"
      assert selection.api_key == "pk-backup"
    end
  end
end
