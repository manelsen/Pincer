defmodule Pincer.E2E.DockerSandboxE2ETest do
  use ExUnit.Case, async: false

  alias Pincer.Adapters.Sandbox.Docker

  @moduletag :docker

  setup do
    assert Docker.available?(), "Docker or Podman CLI must be installed to run :docker E2E tests"

    tmp =
      Path.join(System.tmp_dir!(), "pincer_docker_e2e_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    {:ok, workspace: tmp}
  end

  test "reads and writes confined files under /workspace reflected on host", %{workspace: ws} do
    File.write!(Path.join(ws, "host_input.txt"), "hello-from-host")

    assert {:ok, res} =
             Docker.run(
               "cat /workspace/host_input.txt && echo hello-from-container > /workspace/out.txt",
               workspace_path: ws
             )

    assert res.exit_code == 0
    assert res.backend == :docker
    assert res.output =~ "hello-from-host"
    assert File.read!(Path.join(ws, "out.txt")) |> String.trim() == "hello-from-container"
  end

  test "enforces --network none isolation blocking outbound connections", %{workspace: ws} do
    assert {:ok, res} =
             Docker.run("wget -q -O - --timeout=1 http://1.1.1.1 2>&1", workspace_path: ws)

    assert res.exit_code != 0
    assert res.output =~ ~r/Network unreachable|bad address|unreachable/i
  end

  test "drops all Linux capabilities and enforces no-new-privileges", %{workspace: ws} do
    assert {:ok, res} =
             Docker.run("grep -E '^(CapEff|NoNewPrivs):' /proc/self/status", workspace_path: ws)

    assert res.exit_code == 0
    assert res.output =~ ~r/^CapEff:\s+0{16}$/m
    assert res.output =~ ~r/^NoNewPrivs:\s+1$/m
  end

  test "mounts /tmp as writable yet noexec tmpfs", %{workspace: ws} do
    cmd =
      "printf '#!/bin/sh\necho ran\n' > /tmp/probe.sh && chmod +x /tmp/probe.sh && /tmp/probe.sh"

    assert {:ok, res} = Docker.run(cmd, workspace_path: ws)
    assert res.exit_code != 0
    assert res.output =~ ~r/Permission denied/i
  end

  test "rejects cwd path traversal before invoking Docker", %{workspace: ws} do
    assert {:error, reason} =
             Docker.run("pwd",
               workspace_path: ws,
               cwd: Path.join(ws, "../outside")
             )

    assert reason =~ ~r/Path traversal|Access denied/i
  end
end
