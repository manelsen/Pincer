defmodule Pincer.Adapters.Sandbox.BwrapIntegrationTest do
  use ExUnit.Case, async: false

  alias Pincer.Adapters.Sandbox.Bwrap
  alias Pincer.Adapters.Sandbox.Local

  # Availability is decided once at compile time. `:bwrap` is excluded from
  # default runs in test_helper.exs; run explicitly with
  # `mix test test/pincer/adapters/sandbox/bwrap_integration_test.exs --include bwrap`.
  if Bwrap.available?() and match?(:ok, Bwrap.validate_limits()) do
    @moduletag :bwrap
  else
    @moduletag :bwrap
    @moduletag skip: "bwrap unavailable on this host"
  end

  @moduletag timeout: 120_000

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "pincer_bwrap_it_#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)

    {:ok, workspace: workspace}
  end

  test "runs as the invoking host uid", %{workspace: workspace} do
    write_script!(workspace, "uid.sh", "#!/bin/sh\nid -u\n")

    assert {:ok, %{output: output, exit_code: 0}} = run_script("uid.sh", workspace)

    {host_uid, 0} = System.cmd("id", ["-u"])
    assert String.trim(output) == String.trim(host_uid)
  end

  test "exposes a minimal root with no host /etc or /home", %{workspace: workspace} do
    write_script!(workspace, "root.sh", "#!/bin/sh\nls -A /\n")

    assert {:ok, %{output: output, exit_code: 0}} = run_script("root.sh", workspace)

    entries = output |> String.split("\n", trim: true) |> Enum.sort()

    assert "usr" in entries
    assert "proc" in entries
    assert "dev" in entries
    assert "tmp" in entries
    assert "workspace" in entries

    refute "etc" in entries
    refute "home" in entries
    refute "root" in entries
    refute "var" in entries
  end

  test "does not expose /etc/shadow", %{workspace: workspace} do
    write_script!(
      workspace,
      "shadow.sh",
      "#!/bin/sh\nif [ -e /etc/shadow ]; then exit 1; else exit 0; fi\n"
    )

    assert {:ok, %{exit_code: 0}} = run_script("shadow.sh", workspace)
  end

  test "writes through to the host workspace", %{workspace: workspace} do
    write_script!(
      workspace,
      "write.sh",
      "#!/bin/sh\necho bwrap-write-through > /workspace/bwrap-write-probe.txt\n"
    )

    assert {:ok, %{exit_code: 0}} = run_script("write.sh", workspace)

    assert File.read!(Path.join(workspace, "bwrap-write-probe.txt")) ==
             "bwrap-write-through\n"
  end

  test "blocks outbound network and DNS", %{workspace: workspace} do
    write_script!(
      workspace,
      "network.sh",
      """
      #!/bin/sh
      command -v curl >/dev/null 2>&1 || exit 2
      curl -sS --max-time 3 http://example.com >/dev/null 2>&1 && exit 1
      exit 0
      """
    )

    assert {:ok, %{exit_code: 0}} = run_script("network.sh", workspace)
  end

  test "mounts /usr read-only", %{workspace: workspace} do
    write_script!(
      workspace,
      "ro-usr.sh",
      "#!/bin/sh\nif touch /usr/pincer_ro_probe_$$ 2>/dev/null; then exit 1; else exit 0; fi\n"
    )

    assert {:ok, %{exit_code: 0}} = run_script("ro-usr.sh", workspace)
  end

  defp run_script(name, workspace) do
    Local.run("./#{name}",
      transport: :bwrap,
      workspace_path: workspace,
      cwd: workspace,
      timeout_ms: 20_000
    )
  end

  defp write_script!(workspace, name, body) do
    path = Path.join(workspace, name)
    File.write!(path, body)
    File.chmod!(path, 0o755)
    path
  end
end
