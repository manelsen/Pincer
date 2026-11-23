defmodule Mix.Tasks.Pincer.OnboardTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias Pincer.Core.Onboard.Preflight

  @task "pincer.onboard"

  setup do
    root =
      Path.join(System.tmp_dir!(), "pincer_onboard_task_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)

    # `maybe_capture_api_key/3` calls System.put_env/2, which outlives the test
    # process and would leak into the rest of the suite.
    previous_key = System.get_env("OPENROUTER_API_KEY")

    on_exit(fn ->
      File.rm_rf!(root)
      Mix.Task.reenable(@task)

      if previous_key,
        do: System.put_env("OPENROUTER_API_KEY", previous_key),
        else: System.delete_env("OPENROUTER_API_KEY")
    end)

    {:ok, root: root}
  end

  defp run_task(root, args) do
    Mix.Task.run(@task, ["--root", root, "--non-interactive", "--yes" | args])
  end

  defp config_path(root), do: Path.join(root, "config.yaml")
  defp template_dir(root), do: Path.join(root, "tmp/test_workspaces/.template/.pincer")

  test "non-interactive run creates config and folders", %{root: root} do
    output =
      capture_io(fn ->
        run_task(root, [])
      end)

    assert File.exists?(config_path(root))
    assert File.dir?(Path.join(root, "sessions"))
    assert File.dir?(Path.join(root, "memory"))
    assert File.exists?(Path.join(template_dir(root), "BOOTSTRAP.md"))
    assert File.exists?(Path.join(template_dir(root), "MEMORY.md"))
    assert File.exists?(Path.join(template_dir(root), "HISTORY.md"))

    {:ok, config} = YamlElixir.read_from_file(config_path(root))
    assert get_in(config, ["storage", "adapter"]) == "sqlite"
    assert get_in(config, ["storage", "path"]) == "data/pincer.db"
    assert output =~ "add {:pincer_whatsapp"
    assert output =~ "channels.whatsapp.enabled=true"
  end

  test "if-missing skips when workspace is already onboarded", %{root: root} do
    capture_io(fn ->
      run_task(root, [])
    end)

    Mix.Task.reenable(@task)

    output =
      capture_io(fn ->
        run_task(root, ["--if-missing"])
      end)

    assert output =~ "already onboarded"
  end

  test "--sqlite-path flag overrides storage path", %{root: root} do
    capture_io(fn ->
      run_task(root, ["--sqlite-path", "data/custom.db"])
    end)

    {:ok, config} = YamlElixir.read_from_file(config_path(root))
    assert get_in(config, ["storage", "adapter"]) == "sqlite"
    assert get_in(config, ["storage", "path"]) == "data/custom.db"
  end

  test "capabilities flag limits onboarding operations", %{root: root} do
    capture_io(fn ->
      run_task(root, ["--capabilities", "workspace_dirs,config_yaml"])
    end)

    assert File.dir?(Path.join(root, "sessions"))
    assert File.dir?(Path.join(root, "memory"))
    assert File.exists?(config_path(root))
    refute File.exists?(Path.join(template_dir(root), "MEMORY.md"))
    refute File.exists?(Path.join(template_dir(root), "HISTORY.md"))
  end

  test "invalid capabilities raise explicit error", %{root: root} do
    assert_raise Mix.Error, ~r/Invalid onboarding capabilities/, fn ->
      capture_io(fn ->
        run_task(root, ["--capabilities", "workspace_dirs,not_real"])
      end)
    end
  end

  test "fails when config overrides are used without config_yaml capability", %{root: root} do
    assert_raise Mix.Error, ~r/requires config_yaml capability/, fn ->
      capture_io(fn ->
        run_task(root, [
          "--capabilities",
          "workspace_dirs,memory_file",
          "--sqlite-path",
          "data/custom.db"
        ])
      end)
    end
  end

  test "preflight fails for an unwritable SQLite path", %{root: root} do
    blocker = Path.join(root, "not_a_dir")
    File.write!(blocker, "file")

    assert_raise Mix.Error, ~r/Onboarding preflight failed/, fn ->
      capture_io(fn ->
        run_task(root, ["--sqlite-path", Path.join(blocker, "pincer.db")])
      end)
    end
  end

  test "writes the workspace template under the given root", %{root: root} do
    workspaces = Path.join(root, "tmp/test_workspaces")
    File.mkdir_p!(workspaces)
    File.write!(Path.join(workspaces, "marker.txt"), "keep me")

    capture_io(fn ->
      run_task(root, [])
    end)

    template = Path.join(workspaces, ".template/.pincer")

    assert File.exists?(Path.join(template, "BOOTSTRAP.md"))
    assert File.exists?(Path.join(template, "IDENTITY.md"))
    assert File.exists?(Path.join(template, "SOUL.md"))
    assert File.exists?(Path.join(template, "USER.md"))
    assert File.exists?(Path.join(template, "MEMORY.md"))
    assert File.exists?(Path.join(template, "HISTORY.md"))
    assert File.exists?(config_path(root))
    assert File.dir?(Path.join(root, "sessions"))
    assert File.exists?(Path.join(workspaces, "marker.txt"))
  end

  test "merges existing config.yaml preserving custom sections", %{root: root} do
    File.write!(
      config_path(root),
      """
      storage:
        adapter: "sqlite"
        path: "data/existing.db"
        vec: "false"
      llm:
        provider: "z_ai"
        z_ai:
          base_url: "https://custom.example/v1"
          default_model: "existing-model"
        custom_provider:
          base_url: "https://custom-provider.example/v1"
          default_model: "cp-model"
      custom_section:
        keep_me: true
      """
    )

    capture_io(fn ->
      run_task(root, ["--sqlite-path", "data/merged.db"])
    end)

    {:ok, config} = YamlElixir.read_from_file(config_path(root))

    assert get_in(config, ["storage", "path"]) == "data/merged.db"
    assert get_in(config, ["storage", "vec"]) == "false"
    assert config["custom_section"]["keep_me"] == true
    assert config["llm"]["custom_provider"]["default_model"] == "cp-model"
    assert config["llm"]["z_ai"]["base_url"] == "https://custom.example/v1"
  end

  test "remote mode fails when remote host is not provided", %{root: root} do
    assert_raise Mix.Error, ~r/--remote-host is required/i, fn ->
      capture_io(fn ->
        run_task(root, ["--mode", "remote"])
      end)
    end
  end

  test "remote mode prints assisted plan and does not write local onboarding files", %{root: root} do
    output =
      capture_io(fn ->
        run_task(root, [
          "--mode",
          "remote",
          "--remote-host",
          "vps.example.com",
          "--remote-user",
          "deploy",
          "--remote-path",
          "/srv/pincer",
          "--capabilities",
          "workspace_dirs,config_yaml",
          "--sqlite-path",
          "data/remote.db",
          "--provider",
          "openrouter",
          "--model",
          "openrouter/free"
        ])
      end)

    assert output =~ "Remote assisted onboarding plan"
    assert output =~ "ssh deploy@vps.example.com"
    assert output =~ "mix pincer.onboard --non-interactive --yes"
    refute File.exists?(config_path(root))
    refute File.exists?(Path.join(template_dir(root), "MEMORY.md"))
    refute File.exists?(Path.join(template_dir(root), "HISTORY.md"))
  end

  describe "provider_env_key" do
    test "returns correct env var for known providers" do
      alias Pincer.Core.Onboard.Defaults

      assert Defaults.provider_env_key("openrouter") == "OPENROUTER_API_KEY"
      assert Defaults.provider_env_key("z_ai") == "Z_AI_API_KEY"
      assert Defaults.provider_env_key("z_ai_coding") == "Z_AI_CODING_API_KEY"
      assert Defaults.provider_env_key("opencode_zen") == "OPENCODE_ZEN_API_KEY"
      assert Defaults.provider_env_key("google") == "GOOGLE_API_KEY"
      assert Defaults.provider_env_key("moonshot") == "MOONSHOT_API_KEY"
      assert Defaults.provider_env_key("groq") == "GROQ_API_KEY"
      assert Defaults.provider_env_key("anthropic") == "ANTHROPIC_API_KEY"
    end

    test "returns nil for unknown provider" do
      assert Pincer.Core.Onboard.Defaults.provider_env_key("unknown_provider") == nil
      assert Pincer.Core.Onboard.Defaults.provider_env_key(nil) == nil
    end
  end

  describe "write_env_key via --api-key flag" do
    test "non-interactive with --api-key writes key to .env", %{root: root} do
      capture_io(fn ->
        run_task(root, ["--provider", "openrouter", "--api-key", "test-key-abc123"])
      end)

      assert File.exists?(Path.join(root, ".env"))
      content = File.read!(Path.join(root, ".env"))
      assert content =~ "OPENROUTER_API_KEY=test-key-abc123"
    end

    test "non-interactive without --api-key does not create .env", %{root: root} do
      capture_io(fn ->
        run_task(root, ["--provider", "openrouter"])
      end)

      refute File.exists?(Path.join(root, ".env"))
    end

    test "--api-key replaces existing key without touching other keys", %{root: root} do
      File.write!(
        Path.join(root, ".env"),
        "OTHER_KEY=keep_me\nOPENROUTER_API_KEY=old_value\nANOTHER=also_keep\n"
      )

      capture_io(fn ->
        run_task(root, ["--provider", "openrouter", "--api-key", "new_value"])
      end)

      content = File.read!(Path.join(root, ".env"))
      assert content =~ "OPENROUTER_API_KEY=new_value"
      refute content =~ "OPENROUTER_API_KEY=old_value"
      assert content =~ "OTHER_KEY=keep_me"
      assert content =~ "ANOTHER=also_keep"
    end

    test "--api-key appends to existing .env when key is absent", %{root: root} do
      File.write!(Path.join(root, ".env"), "TELEGRAM_BOT_TOKEN=tg_token\n")

      capture_io(fn ->
        run_task(root, ["--provider", "openrouter", "--api-key", "appended_key"])
      end)

      content = File.read!(Path.join(root, ".env"))
      assert content =~ "TELEGRAM_BOT_TOKEN=tg_token"
      assert content =~ "OPENROUTER_API_KEY=appended_key"
    end
  end

  describe "check_db_connectivity" do
    test "returns :ok for a writable SQLite path" do
      tmp =
        Path.join(System.tmp_dir!(), "pincer_onboard_conn_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf(tmp) end)

      config = %{"storage" => %{"adapter" => "sqlite", "path" => Path.join(tmp, "pincer.db")}}
      assert :ok = Preflight.check_db_connectivity(config)
    end

    test "returns {:warn, _} when the SQLite path escapes its root" do
      config = %{"storage" => %{"adapter" => "sqlite", "path" => "../outside/pincer.db"}}
      assert {:warn, msg} = Preflight.check_db_connectivity(config)
      assert msg =~ "SQLite indisponível"
    end
  end

  describe "zero-infra sqlite flags" do
    test "supports --storage sqlite, --sqlite-path, and --config in non-interactive mode",
         %{root: root} do
      output =
        capture_io(fn ->
          run_task(root, [
            "--storage",
            "sqlite",
            "--sqlite-path",
            "data/custom_zero.db",
            "--config",
            "custom/pincer.yaml"
          ])
        end)

      assert File.exists?(Path.join(root, "custom/pincer.yaml"))
      {:ok, config} = YamlElixir.read_from_file(Path.join(root, "custom/pincer.yaml"))
      refute Map.has_key?(config, "database")
      assert get_in(config, ["storage", "adapter"]) == "sqlite"
      assert get_in(config, ["storage", "path"]) == "data/custom_zero.db"
      assert get_in(config, ["sandbox", "adapter"]) == "local"
      assert output =~ "SQLite"
    end

    test "switching an existing postgres config to --storage sqlite removes postgres database block",
         %{root: root} do
      File.write!(config_path(root), """
      database:
        adapter: "postgres"
        hostname: "localhost"
        database: "pincer"
      custom_keep:
        flag: true
      """)

      capture_io(fn ->
        run_task(root, ["--storage", "sqlite"])
      end)

      {:ok, config} = YamlElixir.read_from_file(config_path(root))
      refute Map.has_key?(config, "database")
      assert get_in(config, ["storage", "adapter"]) == "sqlite"
      assert get_in(config, ["custom_keep", "flag"]) == true
    end

    test "raises Mix.Error on invalid --storage backend", %{root: root} do
      assert_raise Mix.Error, ~r/Invalid storage backend/i, fn ->
        capture_io(fn ->
          run_task(root, ["--storage", "mysql"])
        end)
      end
    end

    test "raises when --sqlite-path or --storage is used without config_yaml capability",
         %{root: root} do
      assert_raise Mix.Error, ~r/requires config_yaml capability/, fn ->
        capture_io(fn ->
          run_task(root, ["--capabilities", "workspace_dirs", "--storage", "sqlite"])
        end)
      end
    end
  end
end
