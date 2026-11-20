defmodule Pincer.Adapters.Sandbox.SSHTest do
  use ExUnit.Case, async: true

  alias Pincer.Adapters.Sandbox.SSH

  defp conformance_run_opts(_workspace) do
    [
      executable: "/usr/bin/ssh",
      host: "sandbox.example.internal",
      user: "pincer",
      runner: fn _exe, _args, _opts -> {"conformance-ok\n", 0} end
    ]
  end

  use Pincer.Test.Support.SandboxConformance, adapter: SSH, backend: :ssh

  describe "validation & option-injection guards" do
    test "rejects missing or empty host" do
      assert {:error, :missing_ssh_host} = SSH.build_args("echo hi", [])
      assert {:error, :missing_ssh_host} = SSH.build_args("echo hi", host: "   ")
    end

    test "rejects leading-dash host or user (SSH option injection)" do
      assert {:error, :invalid_ssh_host} = SSH.build_args("echo hi", host: "-oProxyCommand=id")
      assert {:error, :invalid_ssh_host} = SSH.build_args("echo hi", host: "host;rm -rf /")

      assert {:error, :invalid_ssh_user} =
               SSH.build_args("echo hi", host: "ok.host", user: "-evil")

      assert {:error, :invalid_ssh_user} = SSH.build_args("echo hi", host: "ok.host", user: "a b")
    end

    test "rejects invalid port values" do
      assert {:error, :invalid_ssh_port} = SSH.build_args("echo hi", host: "ok.host", port: 0)

      assert {:error, :invalid_ssh_port} =
               SSH.build_args("echo hi", host: "ok.host", port: 70_000)

      assert {:error, :invalid_ssh_port} = SSH.build_args("echo hi", host: "ok.host", port: "abc")
    end
  end

  describe "build_args/2" do
    test "builds hardened BatchMode SSH args with ControlMaster and remote cwd" do
      assert {:ok, args} =
               SSH.build_args("ls -la",
                 host: "build.internal",
                 user: "agent",
                 port: 2222,
                 identity_file: "/home/pincer/.ssh/id_ed25519",
                 control_path: "/tmp/pincer-ssh-%r@%h:%p",
                 remote_workspace: "/srv/workspaces/app",
                 env: [{"MIX_ENV", "prod"}]
               )

      assert contains_pair?(args, "-o", "BatchMode=yes")
      assert contains_pair?(args, "-o", "StrictHostKeyChecking=yes")
      assert contains_pair?(args, "-p", "2222")
      assert contains_pair?(args, "-i", "/home/pincer/.ssh/id_ed25519")
      assert contains_pair?(args, "-o", "ControlMaster=auto")
      assert contains_pair?(args, "-o", "ControlPath=/tmp/pincer-ssh-%r@%h:%p")
      assert "agent@build.internal" in args

      remote_cmd = List.last(args)
      assert String.contains?(remote_cmd, "cd '/srv/workspaces/app'")
      assert String.contains?(remote_cmd, "export MIX_ENV='prod'")
      assert String.ends_with?(remote_cmd, "ls -la")
    end
  end

  describe "run/2 & cleanup/2" do
    test "returns {:error, :ssh_unavailable} when ssh binary missing" do
      assert {:error, :ssh_unavailable} =
               SSH.run("echo hi", host: "ok.host", executable: nil, which: fn _ -> nil end)
    end

    test "executes remote command and maps exit code" do
      test_pid = self()

      runner = fn exe, args, _opts ->
        send(test_pid, {:ssh_exec, exe, args})
        {"remote out", 0}
      end

      assert {:ok,
              %{output: "remote out", exit_code: 0, backend: :ssh, metadata: %{target: "u@h"}}} =
               SSH.run("pwd",
                 executable: "/usr/bin/ssh",
                 host: "h",
                 user: "u",
                 runner: runner
               )

      assert_received {:ssh_exec, "/usr/bin/ssh", args}
      assert "u@h" in args
    end

    test "enforces timeout_ms" do
      slow = fn _exe, _args, _opts ->
        Process.sleep(300)
        {"late", 0}
      end

      assert {:error, :timeout} =
               SSH.run("sleep 5",
                 executable: "/usr/bin/ssh",
                 host: "h",
                 runner: slow,
                 timeout_ms: 30
               )
    end

    test "cleanup/2 closes ControlMaster socket when configured" do
      runner = fn "/usr/bin/ssh", args, _opts ->
        send(self(), {:ssh_cleanup, args})
        {"", 0}
      end

      assert :ok =
               SSH.cleanup("scope-1",
                 executable: "/usr/bin/ssh",
                 host: "h",
                 user: "u",
                 control_path: "/tmp/ctrl.sock",
                 runner: runner
               )

      assert_received {:ssh_cleanup, ["-O", "exit", "-S", "/tmp/ctrl.sock", "u@h"]}
    end
  end

  defp contains_pair?(list, first, second) do
    list
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.any?(&(&1 == [first, second]))
  end
end
