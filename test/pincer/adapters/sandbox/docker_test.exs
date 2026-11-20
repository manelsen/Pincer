defmodule Pincer.Adapters.Sandbox.DockerTest do
  use ExUnit.Case, async: true

  alias Pincer.Adapters.Sandbox.Docker

  defp conformance_run_opts(workspace) do
    [
      executable: "docker",
      workspace_path: workspace,
      cwd: workspace,
      runner: fn _exe, _args, _opts -> {"conformance-ok\n", 0} end
    ]
  end

  use Pincer.Test.Support.SandboxConformance, adapter: Docker, backend: :docker

  describe "build_args/2" do
    test "includes hardened security, resource, tmpfs, and network none flags by default" do
      workspace =
        Path.join(System.tmp_dir!(), "pincer_docker_build_#{System.unique_integer([:positive])}")

      File.mkdir_p!(workspace)
      on_exit(fn -> File.rm_rf(workspace) end)

      assert {:ok, args} = Docker.build_args("echo hi", workspace_path: workspace)

      assert Enum.take(args, 2) == ["run", "--rm"]
      assert contains_pair?(args, "--cap-drop", "ALL")
      assert contains_pair?(args, "--security-opt", "no-new-privileges")
      assert contains_pair?(args, "--network", "none")
      assert "--pids-limit" in args
      assert "--memory" in args
      assert "--cpus" in args
      assert Enum.any?(args, &String.starts_with?(&1, "/tmp:"))
      assert Enum.any?(args, &String.starts_with?(&1, "/var/tmp:"))
      assert contains_pair?(args, "--label", "pincer-sandbox=1")
      assert contains_pair?(args, "-v", "#{Path.expand(workspace)}:/workspace:rw")
      assert contains_pair?(args, "-w", "/workspace")
      assert Enum.take(args, -3) == ["sh", "-c", "echo hi"]
    end

    test "supports custom image, network mode, snap_compat, relative cwd, labels, and env" do
      workspace =
        Path.join(System.tmp_dir!(), "pincer_docker_opts_#{System.unique_integer([:positive])}")

      subdir = Path.join(workspace, "apps/core")
      File.mkdir_p!(subdir)
      on_exit(fn -> File.rm_rf(workspace) end)

      assert {:ok, args} =
               Docker.build_args("mix test",
                 workspace_path: workspace,
                 cwd: subdir,
                 image: "elixir:1.18-alpine",
                 network: "bridge",
                 snap_compat: true,
                 pids_limit: 512,
                 memory: "1g",
                 cpus: "1.5",
                 scope_id: "sess:Alice/123!@#",
                 env: [{"MIX_ENV", "test"}]
               )

      refute "no-new-privileges" in args
      assert contains_pair?(args, "--network", "bridge")
      assert contains_pair?(args, "--pids-limit", "512")
      assert contains_pair?(args, "--memory", "1g")
      assert contains_pair?(args, "--cpus", "1.5")
      assert contains_pair?(args, "-w", "/workspace/apps/core")
      assert contains_pair?(args, "-e", "MIX_ENV=test")
      assert contains_pair?(args, "--label", "pincer-scope=sess_Alice_123___")
      assert "elixir:1.18-alpine" in args
    end

    test "sanitizes overly long scope labels to 63 chars" do
      long_scope = String.duplicate("aB1-", 30)
      label = Docker.sanitize_label(long_scope)
      assert String.length(label) <= 63
      assert Regex.match?(~r/^[A-Za-z0-9_.-]+$/, label)
    end
  end

  describe "run/2" do
    test "returns {:error, :docker_unavailable} when runtime binary is missing" do
      assert {:error, :docker_unavailable} =
               Docker.run("echo hi",
                 executable: nil,
                 which: fn _ -> nil end,
                 env_finder: fn _ -> nil end
               )
    end

    test "captures output and exit code from container runner" do
      workspace =
        Path.join(System.tmp_dir!(), "pincer_docker_run_#{System.unique_integer([:positive])}")

      File.mkdir_p!(workspace)
      on_exit(fn -> File.rm_rf(workspace) end)

      test_pid = self()

      runner = fn exe, args, _opts ->
        send(test_pid, {:docker_exec, exe, args})
        {"test failed\n", 1}
      end

      assert {:ok,
              %{
                output: "test failed\n",
                exit_code: 1,
                backend: :docker,
                metadata: %{executable: "/usr/bin/docker"}
              }} =
               Docker.run("mix test",
                 executable: "/usr/bin/docker",
                 workspace_path: workspace,
                 runner: runner
               )

      assert_received {:docker_exec, "/usr/bin/docker", ["run", "--rm" | _]}
    end

    test "enforces timeout_ms" do
      workspace =
        Path.join(System.tmp_dir!(), "pincer_docker_to_#{System.unique_integer([:positive])}")

      File.mkdir_p!(workspace)
      on_exit(fn -> File.rm_rf(workspace) end)

      slow_runner = fn _exe, _args, _opts ->
        Process.sleep(300)
        {"late", 0}
      end

      assert {:error, :timeout} =
               Docker.run("sleep 10",
                 executable: "/usr/bin/docker",
                 workspace_path: workspace,
                 runner: slow_runner,
                 timeout_ms: 30
               )
    end
  end

  describe "cleanup/2" do
    test "removes containers matching sanitized scope label" do
      test_pid = self()

      runner = fn
        "/usr/bin/docker", ["ps", "-aq", "--filter", "label=pincer-scope=scope_1"], _opts ->
          send(test_pid, :docker_ps)
          {"cid111\ncid222\n", 0}

        "/usr/bin/docker", ["rm", "-f", "cid111", "cid222"], _opts ->
          send(test_pid, {:docker_rm, ["cid111", "cid222"]})
          {"", 0}
      end

      assert :ok =
               Docker.cleanup("scope/1",
                 executable: "/usr/bin/docker",
                 runner: runner
               )

      assert_received :docker_ps
      assert_received {:docker_rm, ["cid111", "cid222"]}
    end
  end

  defp contains_pair?(list, first, second) do
    list
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.any?(&(&1 == [first, second]))
  end
end
