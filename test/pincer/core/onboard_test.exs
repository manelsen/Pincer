defmodule Pincer.Core.OnboardTest do
  use ExUnit.Case, async: false

  alias Pincer.Core.Onboard
  alias Pincer.Core.Onboard.Defaults
  alias Pincer.Core.Onboard.Preflight

  describe "defaults/0" do
    test "includes embedded SQLite storage defaults" do
      defaults = Onboard.defaults()
      refute Map.has_key?(defaults, "database")
      assert get_in(defaults, ["storage", "adapter"]) == "sqlite"
      assert get_in(defaults, ["storage", "path"]) == "data/pincer.db"
      assert get_in(defaults, ["storage", "vec"]) == "auto"
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
      tmp =
        Path.join(System.tmp_dir!(), "pincer_onboard_scope_#{System.unique_integer([:positive])}")

      workspaces = Path.join(tmp, ".workspaces")

      assert {:ok, plan} =
               Onboard.plan(Onboard.defaults(),
                 capabilities: ["workspace_dirs"],
                 workspaces_dir: workspaces
               )

      assert {:mkdir_p, workspaces} in plan
      assert {:mkdir_p, "sessions"} in plan
      assert {:mkdir_p, "memory"} in plan

      mem_path = "#{workspaces}/.template/.pincer/MEMORY.md"
      hist_path = "#{workspaces}/.template/.pincer/HISTORY.md"

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
    setup do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "pincer_obtain_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)
      %{tmp: tmp, workspaces: Path.join(tmp, "workspaces")}
    end

    test "writes config and creates required folders", %{tmp: tmp, workspaces: workspaces} do
      assert {:ok, plan} = Onboard.plan(Onboard.defaults(), workspaces_dir: workspaces)

      assert {:ok, report} = Onboard.apply_plan(plan, root: tmp)
      assert is_map(report)
      assert File.dir?(workspaces)
      assert File.dir?(Path.join(tmp, "sessions"))
      assert File.dir?(Path.join(tmp, "memory"))
      assert File.exists?(Path.join(tmp, "config.yaml"))
    end

    test "seeds the template under the requested workspaces_dir", %{
      tmp: tmp,
      workspaces: workspaces
    } do
      assert {:ok, plan} =
               Onboard.plan(Onboard.defaults(),
                 capabilities: ["memory_file"],
                 workspaces_dir: workspaces
               )

      template_file = Path.join(workspaces, ".template/.pincer/IDENTITY.md")
      assert Enum.any?(plan, &match?({:write_if_missing, ^template_file, _}, &1))

      assert {:ok, _report} = Onboard.apply_plan(plan, root: tmp)
      assert File.read!(template_file) == Pincer.Core.AgentPaths.default_identity()
    end

    test "resolves relative operation paths against root", %{tmp: tmp} do
      plan = [{:mkdir_p, "custom/deep"}]

      assert {:ok, %{created: ["custom/deep"]}} = Onboard.apply_plan(plan, root: tmp)
      assert File.dir?(Path.join(tmp, "custom/deep"))
      refute File.dir?(Path.join(File.cwd!(), "custom/deep"))
    end

    test "keeps absolute operation paths untouched", %{tmp: tmp} do
      outside =
        Path.join(System.tmp_dir!(), "pincer_obtain_abs_#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf!(outside) end)

      plan = [{:mkdir_p, outside}]

      assert {:ok, %{created: [^outside]}} = Onboard.apply_plan(plan, root: tmp)
      assert File.dir?(outside)
      refute File.dir?(Path.join(tmp, outside))
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

    test "returns error issues with hint for an unwritable SQLite path" do
      config = put_in(Onboard.defaults(), ["storage", "path"], "../outside/pincer.db")

      assert {:error, issues} = Onboard.preflight(config)

      assert Enum.any?(issues, fn issue ->
               issue.id == :invalid_sqlite_path and
                 String.contains?(issue.hint, "writable")
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

  describe "modular components" do
    test "defaults module keeps the canonical onboarding capabilities" do
      assert Defaults.available_capabilities() == Onboard.available_capabilities()
    end

    test "preflight module validates invalid SQLite paths explicitly" do
      config = put_in(Onboard.defaults(), ["storage", "path"], "../outside/pincer.db")

      assert {:error, issues} = Preflight.preflight(config)
      assert Enum.any?(issues, &(&1.id == :invalid_sqlite_path))
    end
  end

  describe "merge_config/2" do
    test "deep-merges defaults and existing config without dropping custom keys" do
      existing = %{
        "storage" => %{"adapter" => "sqlite", "path" => "data/existing.db", "vec" => "false"},
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

      assert get_in(merged, ["storage", "path"]) == "data/existing.db"
      assert get_in(merged, ["storage", "vec"]) == "false"
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
        Onboard.defaults(storage: :sqlite, sqlite_path: "data/remote.db")
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
      assert String.contains?(plan.onboard_command, "--storage 'sqlite'")
      assert String.contains?(plan.onboard_command, "--sqlite-path 'data/remote.db'")
      assert String.contains?(plan.onboard_command, "--provider 'openrouter'")
      assert String.contains?(plan.onboard_command, "--model 'openrouter/free'")
      assert String.contains?(plan.onboard_command, "--capabilities 'workspace_dirs,config_yaml'")
      assert Enum.any?(plan.steps, &String.contains?(&1, "ssh deploy@vps.example.com"))
    end

    test "builds sqlite remote onboard command when config uses sqlite storage" do
      config =
        Onboard.defaults(storage: :sqlite, sqlite_path: "data/remote.db")
        |> put_in(["llm", "provider"], "openrouter")
        |> put_in(["llm", "openrouter", "default_model"], "openrouter/free")

      assert {:ok, plan} =
               Onboard.remote_assisted_plan(config,
                 remote_host: "vps.example.com",
                 remote_user: "deploy",
                 remote_path: "/srv/pincer"
               )

      assert String.contains?(plan.onboard_command, "--storage 'sqlite'")
      assert String.contains?(plan.onboard_command, "--sqlite-path 'data/remote.db'")
    end
  end

  describe "zero-infra sqlite defaults and preflight" do
    test "defaults(storage: :sqlite) emits storage and local sandbox config without postgres" do
      defaults = Onboard.defaults(storage: :sqlite, sqlite_path: "tmp/local.db")

      refute Map.has_key?(defaults, "database")
      assert get_in(defaults, ["storage", "adapter"]) == "sqlite"
      assert get_in(defaults, ["storage", "path"]) == "tmp/local.db"
      assert get_in(defaults, ["sandbox", "adapter"]) == "local"
      assert Defaults.sqlite_storage_config?(defaults)
      assert Defaults.sqlite_path(defaults) == "tmp/local.db"
    end

    test "plan/2 supports custom config_file destination" do
      tmp =
        Path.join(System.tmp_dir!(), "pincer_onboard_cfg_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      config = Onboard.defaults(storage: :sqlite, sqlite_path: "data/custom.db")
      assert {:ok, plan} = Onboard.plan(config, config_file: "nested/custom.yaml")
      assert {:write_config_yaml, "nested/custom.yaml", config} in plan

      assert {:ok, report} = Onboard.apply_plan(plan, root: tmp)
      assert "nested/custom.yaml" in report.written
      {:ok, parsed} = YamlElixir.read_from_file(Path.join(tmp, "nested/custom.yaml"))
      assert parsed["storage"]["adapter"] == "sqlite"
      assert parsed["storage"]["path"] == "data/custom.db"
    end

    test "preflight/1 validates sqlite path and rejects traversal or unwritable parent" do
      tmp =
        Path.join(System.tmp_dir!(), "pincer_sqlite_pf_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      valid = Onboard.defaults(storage: :sqlite, sqlite_path: Path.join(tmp, "data/pincer.db"))
      assert :ok = Onboard.preflight(valid)
      assert :ok = Preflight.check_db_connectivity(valid)

      traversal = Onboard.defaults(storage: :sqlite, sqlite_path: "../outside/pincer.db")
      assert {:error, issues_trav} = Onboard.preflight(traversal)
      assert Enum.any?(issues_trav, &(&1.id == :invalid_sqlite_path))

      blocker = Path.join(tmp, "not_a_dir")
      File.write!(blocker, "file")

      blocked_cfg =
        Onboard.defaults(storage: :sqlite, sqlite_path: Path.join(blocker, "pincer.db"))

      assert {:error, issues_blocked} = Onboard.preflight(blocked_cfg)
      assert Enum.any?(issues_blocked, &(&1.id == :invalid_sqlite_path))
    end
  end
end
