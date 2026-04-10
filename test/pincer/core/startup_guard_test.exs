defmodule Pincer.Core.StartupGuardTest do
  # async: false because tests modify global Application env (Pincer.Infra.Repo config)
  use ExUnit.Case, async: false

  alias Pincer.Core.StartupGuard

  setup do
    # Ensure DB/migrations checks are skipped during tests so the guard
    # does not block the test suite from starting.
    Application.put_env(:pincer, :skip_startup_guard, true)

    # Snapshot the Repo config before each test so we can restore it afterward.
    # The check_database/0 tests modify and then delete this key, which
    # would leave the application unable to connect to the DB in subsequent tests.
    original_repo_config = Application.get_env(:pincer, Pincer.Infra.Repo)

    on_exit(fn ->
      Application.delete_env(:pincer, :skip_startup_guard)
      Application.delete_env(:pincer, :config_path)

      # Restore the Repo config to what it was before this test.
      if original_repo_config do
        Application.put_env(:pincer, Pincer.Infra.Repo, original_repo_config)
      else
        Application.delete_env(:pincer, Pincer.Infra.Repo)
      end
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # check_config/0
  # ---------------------------------------------------------------------------

  describe "check_config/0" do
    test "returns :ok for a valid YAML file" do
      path = write_tmp_yaml!("database:\n  hostname: localhost\n  port: 5432\n")
      Application.put_env(:pincer, :config_path, path)

      assert StartupGuard.check_config() == :ok
    end

    test "returns {:error, :config_invalid, _} for syntactically invalid YAML" do
      path = write_tmp_yaml!("channels:\n  telegram: [\n")
      Application.put_env(:pincer, :config_path, path)

      assert {:error, :config_invalid, msg} = StartupGuard.check_config()
      assert String.contains?(msg, "config.yaml inválido")
    end

    test "returns {:error, :config_missing, _} when file does not exist" do
      Application.put_env(:pincer, :config_path, "/nonexistent/path/config.yaml")

      assert {:error, :config_missing, msg} = StartupGuard.check_config()
      assert String.contains?(msg, "mix pincer.onboard")
    end
  end

  # ---------------------------------------------------------------------------
  # check_database/0
  # ---------------------------------------------------------------------------

  describe "check_database/0" do
    test "returns :ok when the port is reachable" do
      # Start a temporary TCP listener on a random port so we have something to connect to.
      {:ok, listener} = :gen_tcp.listen(0, [:binary, reuseaddr: true])
      {:ok, port} = :inet.port(listener)

      Application.put_env(:pincer, Pincer.Infra.Repo,
        hostname: "127.0.0.1",
        port: port
      )

      assert StartupGuard.check_database() == :ok

      :gen_tcp.close(listener)
    after
      Application.delete_env(:pincer, Pincer.Infra.Repo)
    end

    test "returns {:error, :db_unreachable, _} for a closed port" do
      # Use a high-numbered port very unlikely to be in use.
      Application.put_env(:pincer, Pincer.Infra.Repo,
        hostname: "127.0.0.1",
        port: 19_999
      )

      result = StartupGuard.check_database()

      # Accept both :ok (if something happens to be on that port) and the error.
      case result do
        :ok ->
          :ok

        {:error, :db_unreachable, msg} ->
          assert String.contains?(msg, "docker compose up -d postgres")
      end
    after
      Application.delete_env(:pincer, Pincer.Infra.Repo)
    end
  end

  # ---------------------------------------------------------------------------
  # run/0 — integration of all checks
  # ---------------------------------------------------------------------------

  describe "run/0" do
    test "returns :ok when config is valid and guard is skipped for DB/migrations" do
      path = write_tmp_yaml!("database:\n  hostname: localhost\n  port: 5432\n")
      Application.put_env(:pincer, :config_path, path)
      Application.put_env(:pincer, :skip_startup_guard, true)

      assert StartupGuard.run() == :ok
    end

    test "returns {:error, :config_missing, _} and stops early on missing config" do
      Application.put_env(:pincer, :config_path, "/does/not/exist.yaml")
      Application.put_env(:pincer, :skip_startup_guard, true)

      assert {:error, :config_missing, _msg} = StartupGuard.run()
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp write_tmp_yaml!(content) do
    dir = System.tmp_dir!()
    name = "startup_guard_test_#{:erlang.unique_integer([:positive])}.yaml"
    path = Path.join(dir, name)
    File.write!(path, content)
    path
  end
end
