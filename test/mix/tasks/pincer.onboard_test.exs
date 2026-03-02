defmodule Mix.Tasks.Pincer.OnboardTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

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
    capture_io(fn ->
      Mix.Task.run(@task, ["--non-interactive", "--yes"])
    end)

    assert File.exists?("config.yaml")
    assert File.dir?("db")
    assert File.dir?("sessions")
    assert File.dir?("memory")
    assert File.exists?("MEMORY.md")
    assert File.exists?("HISTORY.md")

    {:ok, config} = YamlElixir.read_from_file("config.yaml")
    assert config["database"]["database"] == "db/pincer_mvp.db"
  end

  test "db-path flag overrides database output" do
    capture_io(fn ->
      Mix.Task.run(@task, ["--non-interactive", "--yes", "--db-path", "db/custom.db"])
    end)

    {:ok, config} = YamlElixir.read_from_file("config.yaml")
    assert config["database"]["database"] == "db/custom.db"
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

    assert File.dir?("db")
    assert File.dir?("sessions")
    assert File.dir?("memory")
    assert File.exists?("config.yaml")
    refute File.exists?("MEMORY.md")
    refute File.exists?("HISTORY.md")
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
          "--db-path",
          "db/custom.db"
        ])
      end)
    end
  end

  test "preflight fails with hint for invalid db path" do
    assert_raise Mix.Error, ~r/Onboarding preflight failed/, fn ->
      capture_io(fn ->
        Mix.Task.run(@task, [
          "--non-interactive",
          "--yes",
          "--db-path",
          "../outside.db"
        ])
      end)
    end
  end

  test "merges existing config.yaml preserving custom sections" do
    File.write!(
      "config.yaml",
      """
      database:
        database: "db/existing.db"
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
      Mix.Task.run(@task, ["--non-interactive", "--yes", "--db-path", "db/merged.db"])
    end)

    {:ok, config} = YamlElixir.read_from_file("config.yaml")

    assert config["database"]["database"] == "db/merged.db"
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
          "--db-path",
          "db/remote.db",
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
    refute File.exists?("MEMORY.md")
    refute File.exists?("HISTORY.md")
  end
end
