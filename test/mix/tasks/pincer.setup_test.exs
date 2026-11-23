defmodule Mix.Tasks.Pincer.SetupTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  alias Mix.Tasks.Pincer.Setup

  setup do
    prev_storage = System.get_env("PINCER_STORAGE")

    on_exit(fn ->
      if prev_storage,
        do: System.put_env("PINCER_STORAGE", prev_storage),
        else: System.delete_env("PINCER_STORAGE")

      Mix.Task.reenable("pincer.setup")
      Mix.Task.reenable("pincer.onboard")
    end)

    :ok
  end

  test "run_steps/1 halts immediately on error and skips subsequent steps" do
    test_pid = self()

    steps = [
      {"Step 1",
       fn ->
         send(test_pid, :step_1)
         :ok
       end},
      {"Step 2",
       fn ->
         send(test_pid, :step_2)
         {:error, "database unreachable"}
       end},
      {"Step 3",
       fn ->
         send(test_pid, :step_3)
         :ok
       end}
    ]

    output =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:error, "database unreachable"} = Setup.run_steps(steps)
        end)
      end)

    assert_received :step_1
    assert_received :step_2
    refute_received :step_3
    assert output =~ "database unreachable"
  end

  test "run_steps/1 continues across :ok and {:skip, reason} steps" do
    test_pid = self()

    steps = [
      {"Step 1",
       fn ->
         send(test_pid, :s1)
         :ok
       end},
      {"Step 2",
       fn ->
         send(test_pid, :s2)
         {:skip, "already present"}
       end},
      {"Step 3",
       fn ->
         send(test_pid, :s3)
         :ok
       end}
    ]

    ExUnit.CaptureIO.capture_io(fn ->
      assert :ok = Setup.run_steps(steps)
    end)

    assert_received :s1
    assert_received :s2
    assert_received :s3
  end

  test "build_steps/1 emits only embedded SQLite steps" do
    labels =
      [skip_deps: true]
      |> Setup.build_steps()
      |> Enum.map(&elem(&1, 0))

    assert "Configuração (mix pincer.onboard)" in labels
    assert "Banco embutido SQLite" in labels
    refute Enum.any?(labels, &String.contains?(&1, "ecto"))
  end

  test "build_steps/1 rejects a postgres storage backend" do
    assert_raise Mix.Error, ~r/Invalid storage backend/, fn ->
      Setup.build_steps(storage: "postgres", skip_deps: true)
    end
  end

  test "run/1 with --storage sqlite initializes config and SQLite database without Postgres" do
    tmp = Path.join(System.tmp_dir!(), "pincer_setup_zi_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    File.mkdir_p!(Path.join(tmp, "custom_setup"))

    on_exit(fn -> File.rm_rf!(tmp) end)

    cfg_path = Path.join(tmp, "custom_setup/config.yaml")
    db_path = Path.join(tmp, "custom_setup/pincer_local.db")

    output =
      capture_io(fn ->
        Setup.run([
          "--storage",
          "sqlite",
          "--yes",
          "--skip-deps",
          "--config",
          cfg_path,
          "--sqlite-path",
          db_path,
          "--root",
          tmp
        ])
      end)

    assert File.exists?(cfg_path)
    assert File.exists?(db_path)
    {:ok, cfg} = YamlElixir.read_from_file(cfg_path)
    assert get_in(cfg, ["storage", "adapter"]) == "sqlite"
    assert get_in(cfg, ["storage", "path"]) == db_path
    assert output =~ "SQLite"
  end

  test "run/1 raises Mix.Error on unknown flags" do
    assert_raise Mix.Error, ~r/Invalid flags/, fn ->
      Setup.run(["--nonexistent-flag"])
    end
  end
end
