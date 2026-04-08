defmodule Mix.Tasks.Pincer.OnboardTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias Pincer.Core.Onboard.Preflight

  @task "pincer.onboard"

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "pincer_onboard_task_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    cwd = File.cwd!()
    File.cd!(tmp)

    on_exit(fn ->
      File.cd!(cwd)
      File.rm_rf!(tmp)
      Mix.Task.reenable(@task)
    end)

    :ok
  end

  test "non-interactive run creates config and folders" do
    output =
      capture_io(fn ->
        Mix.Task.run(@task, ["--non-interactive", "--yes"])
      end)

    assert File.exists?("config.yaml")
    assert File.dir?(Pincer.Core.AgentPaths.base_dir())
    assert File.dir?("sessions")
    assert File.dir?("memory")
    assert File.exists?("#{Pincer.Core.AgentPaths.base_dir()}/.template/.pincer/BOOTSTRAP.md")
    assert File.exists?("#{Pincer.Core.AgentPaths.base_dir()}/.template/.pincer/MEMORY.md")
    assert File.exists?("#{Pincer.Core.AgentPaths.base_dir()}/.template/.pincer/HISTORY.md")

    {:ok, config} = YamlElixir.read_from_file("config.yaml")
    assert config["database"]["database"] == "pincer"
    assert config["database"]["hostname"] == "localhost"
    assert output =~ "npm install --prefix infrastructure/whatsapp"
    assert output =~ "channels.whatsapp.enabled=true"
  end

  test "if-missing skips when workspace is already onboarded" do
    capture_io(fn ->
      Mix.Task.run(@task, ["--non-interactive", "--yes"])
    end)

    Mix.Task.reenable(@task)

    output =
      capture_io(fn ->
        Mix.Task.run(@task, ["--non-interactive", "--yes", "--if-missing"])
      end)

    assert output =~ "already onboarded"
  end

  test "db-name flag overrides database output" do
    capture_io(fn ->
      Mix.Task.run(@task, ["--non-interactive", "--yes", "--db-name", "custom_db"])
    end)

    {:ok, config} = YamlElixir.read_from_file("config.yaml")
    assert config["database"]["database"] == "custom_db"
  end

  test "capabilities flag limits onboarding operations" do
    capture_io(fn ->
      Mix.Task.run(@task, [
        "--non-interactive",
        "--yes",
        "--capabilities",
        "workspace_dirs,config_yaml"
      ])
    end)

    assert File.dir?(Pincer.Core.AgentPaths.base_dir())
    assert File.dir?("sessions")
    assert File.dir?("memory")
    assert File.exists?("config.yaml")
    refute File.exists?("#{Pincer.Core.AgentPaths.base_dir()}/.template/.pincer/MEMORY.md")
    refute File.exists?("#{Pincer.Core.AgentPaths.base_dir()}/.template/.pincer/HISTORY.md")
  end

  test "invalid capabilities raise explicit error" do
    assert_raise Mix.Error, ~r/Invalid onboarding capabilities/, fn ->
      capture_io(fn ->
        Mix.Task.run(@task, [
          "--non-interactive",
          "--yes",
          "--capabilities",
          "workspace_dirs,not_real"
        ])
      end)
    end
  end

  test "fails when config overrides are used without config_yaml capability" do
    assert_raise Mix.Error, ~r/requires config_yaml capability/, fn ->
      capture_io(fn ->
        Mix.Task.run(@task, [
          "--non-interactive",
          "--yes",
          "--capabilities",
          "workspace_dirs,memory_file",
          "--db-name",
          "custom_db"
        ])
      end)
    end
  end

  test "preflight fails with hint for invalid database name" do
    assert_raise Mix.Error, ~r/Onboarding preflight failed/, fn ->
      capture_io(fn ->
        Mix.Task.run(@task, [
          "--non-interactive",
          "--yes",
          "--db-name",
          "../outside"
        ])
      end)
    end
  end

  test "merges existing config.yaml preserving custom sections" do
    File.write!(
      "config.yaml",
      """
      database:
        database: "existing_db"
        hostname: "db.internal"
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
      Mix.Task.run(@task, ["--non-interactive", "--yes", "--db-name", "merged_db"])
    end)

    {:ok, config} = YamlElixir.read_from_file("config.yaml")

    assert config["database"]["database"] == "merged_db"
    assert config["database"]["hostname"] == "db.internal"
    assert config["custom_section"]["keep_me"] == true
    assert config["llm"]["custom_provider"]["default_model"] == "cp-model"
    assert config["llm"]["z_ai"]["base_url"] == "https://custom.example/v1"
  end

  test "remote mode fails when remote host is not provided" do
    assert_raise Mix.Error, ~r/--remote-host is required/i, fn ->
      capture_io(fn ->
        Mix.Task.run(@task, [
          "--non-interactive",
          "--mode",
          "remote"
        ])
      end)
    end
  end

  test "remote mode prints assisted plan and does not write local onboarding files" do
    output =
      capture_io(fn ->
        Mix.Task.run(@task, [
          "--non-interactive",
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
          "--db-name",
          "remote_db",
          "--provider",
          "openrouter",
          "--model",
          "openrouter/free"
        ])
      end)

    assert output =~ "Remote assisted onboarding plan"
    assert output =~ "ssh deploy@vps.example.com"
    assert output =~ "mix pincer.onboard --non-interactive --yes"
    refute File.exists?("config.yaml")
    refute File.exists?("#{Pincer.Core.AgentPaths.base_dir()}/.template/.pincer/MEMORY.md")
    refute File.exists?("#{Pincer.Core.AgentPaths.base_dir()}/.template/.pincer/HISTORY.md")
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
    test "non-interactive with --api-key writes key to .env" do
      capture_io(fn ->
        Mix.Task.run(@task, [
          "--non-interactive",
          "--yes",
          "--provider",
          "openrouter",
          "--api-key",
          "test-key-abc123"
        ])
      end)

      assert File.exists?(".env")
      content = File.read!(".env")
      assert content =~ "OPENROUTER_API_KEY=test-key-abc123"
    end

    test "non-interactive without --api-key does not create .env" do
      capture_io(fn ->
        Mix.Task.run(@task, [
          "--non-interactive",
          "--yes",
          "--provider",
          "openrouter"
        ])
      end)

      refute File.exists?(".env")
    end

    test "--api-key replaces existing key without touching other keys" do
      File.write!(".env", "OTHER_KEY=keep_me\nOPENROUTER_API_KEY=old_value\nANOTHER=also_keep\n")

      capture_io(fn ->
        Mix.Task.run(@task, [
          "--non-interactive",
          "--yes",
          "--provider",
          "openrouter",
          "--api-key",
          "new_value"
        ])
      end)

      content = File.read!(".env")
      assert content =~ "OPENROUTER_API_KEY=new_value"
      refute content =~ "OPENROUTER_API_KEY=old_value"
      assert content =~ "OTHER_KEY=keep_me"
      assert content =~ "ANOTHER=also_keep"
    end

    test "--api-key appends to existing .env when key is absent" do
      File.write!(".env", "TELEGRAM_BOT_TOKEN=tg_token\n")

      capture_io(fn ->
        Mix.Task.run(@task, [
          "--non-interactive",
          "--yes",
          "--provider",
          "openrouter",
          "--api-key",
          "appended_key"
        ])
      end)

      content = File.read!(".env")
      assert content =~ "TELEGRAM_BOT_TOKEN=tg_token"
      assert content =~ "OPENROUTER_API_KEY=appended_key"
    end
  end

  describe "check_db_connectivity" do
    test "returns :ok when port is open" do
      {:ok, listen} = :gen_tcp.listen(0, [])
      {:ok, port} = :inet.port(listen)
      config = %{"database" => %{"hostname" => "localhost", "port" => port}}
      assert :ok = Preflight.check_db_connectivity(config)
      :gen_tcp.close(listen)
    end

    test "returns {:warn, _} when port is closed" do
      config = %{"database" => %{"hostname" => "localhost", "port" => 19999}}
      assert {:warn, msg} = Preflight.check_db_connectivity(config)
      assert msg =~ "inacessível"
    end
  end
end
