defmodule Pincer.Core.OnboardTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.Onboard

  describe "defaults/0" do
    test "includes postgres database defaults" do
      defaults = Onboard.defaults()
      assert get_in(defaults, ["database", "adapter"]) == "Ecto.Adapters.PostgreSQL"
      assert get_in(defaults, ["database", "hostname"]) == "localhost"
      assert get_in(defaults, ["database", "database"]) == "pincer"
    end

    test "includes whatsapp channel scaffold disabled by default" do
      defaults = Onboard.defaults()
      assert get_in(defaults, ["channels", "whatsapp", "enabled"]) == false
      assert get_in(defaults, ["channels", "whatsapp", "adapter"]) == "Pincer.Channels.WhatsApp"
      assert get_in(defaults, ["channels", "whatsapp", "bridge", "pairing_phone"]) == ""
    end
  end

  describe "plan/1" do
    test "creates runtime workspace directories without local db folder" do
      plan = Onboard.plan(Onboard.defaults())
      refute {:mkdir_p, "db"} in plan
      assert {:mkdir_p, "sessions"} in plan
    end
  end

  describe "capability-driven plan" do
    test "available_capabilities/0 exposes onboarding capability IDs" do
      assert Onboard.available_capabilities() ==
               ["workspace_dirs", "memory_file", "config_yaml"]
    end

    test "plan/2 scopes operations by selected capabilities" do
      assert {:ok, plan} = Onboard.plan(Onboard.defaults(), capabilities: ["workspace_dirs"])

      assert {:mkdir_p, Pincer.Core.AgentPaths.base_dir()} in plan
      assert {:mkdir_p, "sessions"} in plan
      assert {:mkdir_p, "memory"} in plan

      mem_path = "#{Pincer.Core.AgentPaths.base_dir()}/.template/.pincer/MEMORY.md"
      hist_path = "#{Pincer.Core.AgentPaths.base_dir()}/.template/.pincer/HISTORY.md"

      refute Enum.any?(
               plan,
               &match?({:write_if_missing, ^mem_path, _}, &1)
             )

      refute Enum.any?(
               plan,
               &match?({:write_if_missing, ^hist_path, _}, &1)
             )

      refute Enum.any?(plan, &match?({:write_config_yaml, "config.yaml", _}, &1))
    end

    test "plan/2 returns validation error for unknown capabilities" do
      assert {:error, {:unknown_capabilities, ["not_real"]}} =
               Onboard.plan(Onboard.defaults(), capabilities: ["not_real"])
    end
  end

  describe "apply_plan/2" do
    test "writes config and creates required folders" do
      tmp = Path.join(System.tmp_dir!(), "pincer_onboard_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)

      on_exit(fn ->
        File.rm_rf!(tmp)
      end)

      plan = Onboard.plan(Onboard.defaults())

      assert {:ok, report} = Onboard.apply_plan(plan, root: tmp)
      assert is_map(report)

      assert File.dir?(Path.join(tmp, Pincer.Core.AgentPaths.base_dir()))
      assert File.dir?(Path.join(tmp, "sessions"))
      assert File.dir?(Path.join(tmp, "memory"))
      assert File.exists?(Path.join(tmp, "config.yaml"))

      assert File.exists?(
               Path.join(
                 tmp,
                 "#{Pincer.Core.AgentPaths.base_dir()}/.template/.pincer/BOOTSTRAP.md"
               )
             )

      assert File.exists?(
               Path.join(tmp, "#{Pincer.Core.AgentPaths.base_dir()}/.template/.pincer/MEMORY.md")
             )

      assert File.exists?(
               Path.join(tmp, "#{Pincer.Core.AgentPaths.base_dir()}/.template/.pincer/HISTORY.md")
             )

      {:ok, config} = YamlElixir.read_from_file(Path.join(tmp, "config.yaml"))
      assert config["database"]["database"] == "pincer"
      assert config["database"]["hostname"] == "localhost"
    end
  end

  describe "onboarded?/1" do
    test "returns false when required scaffold files are missing" do
      tmp =
        Path.join(System.tmp_dir!(), "pincer_onboard_state_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)

      on_exit(fn ->
        File.rm_rf!(tmp)
      end)

      refute Onboard.onboarded?(tmp)
    end

    test "returns true after onboarding plan is fully applied" do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "pincer_onboard_state_ready_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp)

      on_exit(fn ->
        File.rm_rf!(tmp)
      end)

      assert {:ok, _report} =
               Onboard.defaults()
               |> Onboard.plan()
               |> Onboard.apply_plan(root: tmp)

      assert Onboard.onboarded?(tmp)
    end
  end

  describe "preflight/1" do
    test "returns :ok for defaults" do
      assert :ok = Onboard.preflight(Onboard.defaults())
    end

    test "returns error issues with hint for invalid database name" do
      config = put_in(Onboard.defaults(), ["database", "database"], "../outside")

      assert {:error, issues} = Onboard.preflight(config)

      assert Enum.any?(issues, fn issue ->
               issue.id == :invalid_db_name and
                 String.contains?(issue.hint, "database name")
             end)
    end

    test "returns error issues for missing provider and model" do
      config =
        Onboard.defaults()
        |> put_in(["llm", "provider"], "")
        |> put_in(["llm", "z_ai", "default_model"], "")

      assert {:error, issues} = Onboard.preflight(config)
      issue_ids = Enum.map(issues, & &1.id)

      assert :missing_provider in issue_ids
      assert :missing_model in issue_ids
    end
  end

  describe "merge_config/2" do
    test "deep-merges defaults and existing config without dropping custom keys" do
      existing = %{
        "database" => %{"database" => "existing_db", "hostname" => "db.internal"},
        "llm" => %{
          "provider" => "z_ai",
          "z_ai" => %{
            "base_url" => "https://custom.example/v1",
            "default_model" => "custom-model"
          },
          "custom_provider" => %{
            "base_url" => "https://custom-provider.example/v1",
            "default_model" => "cp-model"
          }
        },
        "custom_section" => %{"keep_me" => true}
      }

      merged = Onboard.merge_config(Onboard.defaults(), existing)

      assert get_in(merged, ["database", "database"]) == "existing_db"
      assert get_in(merged, ["database", "hostname"]) == "db.internal"
      assert get_in(merged, ["llm", "z_ai", "base_url"]) == "https://custom.example/v1"
      assert get_in(merged, ["llm", "custom_provider", "default_model"]) == "cp-model"
      assert get_in(merged, ["custom_section", "keep_me"]) == true
      assert get_in(merged, ["channels", "telegram", "enabled"]) == true
    end
  end

  describe "assisted_preflight/2" do
    test "returns warnings when environment dependencies are missing" do
      report =
        Onboard.assisted_preflight(Onboard.defaults(),
          env_fetcher: fn _ -> nil end,
          command_checker: fn _ -> false end,
          llm_providers: %{"z_ai" => %{env_key: "Z_AI_API_KEY"}}
        )

      assert report.status == :warn

      assert Enum.any?(report.checks, fn check ->
               check.id == {:channel_token, "telegram"} and check.severity == :warn
             end)

      assert Enum.any?(report.checks, fn check ->
               check.id == {:provider_env, "z_ai"} and check.severity == :warn
             end)

      assert Enum.any?(report.checks, fn check ->
               check.id == {:mcp_command, "npx"} and check.severity == :warn
             end)
    end

    test "returns ok when environment dependencies are available" do
      report =
        Onboard.assisted_preflight(Onboard.defaults(),
          env_fetcher: fn _ -> "present" end,
          command_checker: fn _ -> true end,
          llm_providers: %{"z_ai" => %{env_key: "Z_AI_API_KEY"}}
        )

      assert report.status == :ok
      assert Enum.all?(report.checks, &(&1.severity == :ok))
    end
  end

  describe "remote_assisted_plan/2" do
    test "returns explicit validation error when remote host is missing" do
      assert {:error, issue} = Onboard.remote_assisted_plan(Onboard.defaults(), remote_host: "")
      assert issue.id == :missing_remote_host
    end

    test "returns explicit validation error for invalid remote path" do
      assert {:error, issue} =
               Onboard.remote_assisted_plan(Onboard.defaults(),
                 remote_host: "vps.example.com",
                 remote_path: "relative/path"
               )

      assert issue.id == :invalid_remote_path
    end

    test "builds deterministic remote bootstrap command and steps" do
      config =
        Onboard.defaults()
        |> put_in(["database", "database"], "remote_db")
        |> put_in(["llm", "provider"], "openrouter")
        |> put_in(["llm", "openrouter", "default_model"], "openrouter/free")

      assert {:ok, plan} =
               Onboard.remote_assisted_plan(config,
                 remote_host: "vps.example.com",
                 remote_user: "deploy",
                 remote_path: "/srv/pincer",
                 capabilities: ["workspace_dirs", "config_yaml"]
               )

      assert plan.target == "deploy@vps.example.com"
      assert plan.project_path == "/srv/pincer"
      assert String.contains?(plan.onboard_command, "mix pincer.onboard --non-interactive --yes")
      assert String.contains?(plan.onboard_command, "--db-name 'remote_db'")
      assert String.contains?(plan.onboard_command, "--provider 'openrouter'")
      assert String.contains?(plan.onboard_command, "--model 'openrouter/free'")
      assert String.contains?(plan.onboard_command, "--capabilities 'workspace_dirs,config_yaml'")
      assert Enum.any?(plan.steps, &String.contains?(&1, "ssh deploy@vps.example.com"))
    end
  end
end
