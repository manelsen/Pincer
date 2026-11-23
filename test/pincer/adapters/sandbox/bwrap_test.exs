defmodule Pincer.Adapters.Sandbox.BwrapTest do
  use ExUnit.Case, async: true

  alias Pincer.Adapters.Sandbox.Bwrap

  @system_paths ["/usr", "/bin", "/lib", "/lib64"]

  setup do
    root =
      Path.join(System.tmp_dir!(), "pincer_bwrap_unit_#{System.unique_integer([:positive])}")

    workspace = Path.join(root, "workspace")
    subdir = Path.join(workspace, "apps/core")
    File.mkdir_p!(subdir)

    bwrap = fake_executable!(root, "bwrap")
    prlimit = fake_executable!(root, "prlimit")

    on_exit(fn ->
      Bwrap.reset_probe()
      File.rm_rf(root)
    end)

    {:ok, root: root, workspace: workspace, subdir: subdir, bwrap: bwrap, prlimit: prlimit}
  end

  describe "build_command/2 default argv" do
    test "constructs namespace, mount, cwd, env, and shell argv", %{
      workspace: workspace,
      bwrap: bwrap,
      prlimit: prlimit
    } do
      assert {:ok, {exe, args}} =
               Bwrap.build_command("echo hi",
                 workspace_path: workspace,
                 executable: bwrap,
                 prlimit_executable: prlimit,
                 limits: :disabled
               )

      assert exe == bwrap

      assert Enum.take(args, 4) == [
               "--unshare-all",
               "--die-with-parent",
               "--new-session",
               "--clearenv"
             ]

      for path <- existing_system_paths() do
        assert pair_at?(args, "--ro-bind", path)
      end

      assert pair_at?(args, "--proc", "/proc")
      assert pair_at?(args, "--dev", "/dev")
      assert pair_at?(args, "--tmpfs", "/dev/shm")
      assert pair_at?(args, "--tmpfs", "/tmp")

      assert pair_at?(args, "--bind", Path.expand(workspace))
      assert pair_at?(args, "--chdir", "/workspace")

      assert setenv?(args, "PATH", "/usr/bin:/bin")
      assert setenv?(args, "HOME", "/workspace")
      assert setenv?(args, "TMPDIR", "/tmp")

      assert Enum.take(args, -4) == ["--", "/bin/sh", "-c", "echo hi"]
      refute "--share-net" in args
    end

    test "adds existing extra read-only binds and skips missing ones", %{
      root: root,
      workspace: workspace,
      bwrap: bwrap,
      prlimit: prlimit
    } do
      extra_dir = Path.join(root, "extra")
      File.mkdir_p!(extra_dir)
      missing = Path.join(root, "does-not-exist")

      assert {:ok, {_exe, args}} =
               Bwrap.build_command("pwd",
                 workspace_path: workspace,
                 executable: bwrap,
                 prlimit_executable: prlimit,
                 limits: :disabled,
                 extra_ro_binds: [extra_dir, missing]
               )

      assert pair_at?(args, "--ro-bind", extra_dir)
      refute pair_at?(args, "--ro-bind", missing)
    end

    test "omits the tmpfs mount when tmpfs: false", %{
      workspace: workspace,
      bwrap: bwrap,
      prlimit: prlimit
    } do
      assert {:ok, {_exe, args}} =
               Bwrap.build_command("pwd",
                 workspace_path: workspace,
                 executable: bwrap,
                 prlimit_executable: prlimit,
                 limits: :disabled,
                 tmpfs: false
               )

      refute pair_at?(args, "--tmpfs", "/tmp")
    end
  end

  describe "network" do
    test "network :host adds --share-net and host resolver/CA binds", %{
      workspace: workspace,
      bwrap: bwrap,
      prlimit: prlimit
    } do
      assert {:ok, {_exe, args}} =
               Bwrap.build_command("pwd",
                 workspace_path: workspace,
                 executable: bwrap,
                 prlimit_executable: prlimit,
                 limits: :disabled,
                 network: :host
               )

      assert "--share-net" in args

      for path <- [
            "/etc/resolv.conf",
            "/etc/hosts",
            "/etc/nsswitch.conf",
            "/etc/ssl/certs"
          ],
          File.exists?(path) do
        assert pair_at?(args, "--ro-bind", path)
      end
    end

    test "network \"host\" is accepted", %{
      workspace: workspace,
      bwrap: bwrap,
      prlimit: prlimit
    } do
      assert {:ok, {_exe, args}} =
               Bwrap.build_command("pwd",
                 workspace_path: workspace,
                 executable: bwrap,
                 prlimit_executable: prlimit,
                 limits: :disabled,
                 network: "host"
               )

      assert "--share-net" in args
    end

    test "network :none does not share the network", %{
      workspace: workspace,
      bwrap: bwrap,
      prlimit: prlimit
    } do
      assert {:ok, {_exe, args}} =
               Bwrap.build_command("pwd",
                 workspace_path: workspace,
                 executable: bwrap,
                 prlimit_executable: prlimit,
                 limits: :disabled,
                 network: :none
               )

      refute "--share-net" in args
    end
  end

  describe "workspace and cwd validation" do
    test "maps a cwd equal to the workspace to /workspace", %{
      workspace: workspace,
      bwrap: bwrap,
      prlimit: prlimit
    } do
      assert {:ok, {_exe, args}} =
               Bwrap.build_command("pwd",
                 workspace_path: workspace,
                 cwd: workspace,
                 executable: bwrap,
                 prlimit_executable: prlimit,
                 limits: :disabled
               )

      assert pair_at?(args, "--chdir", "/workspace")
    end

    test "maps a nested cwd relative to /workspace", %{
      workspace: workspace,
      subdir: subdir,
      bwrap: bwrap,
      prlimit: prlimit
    } do
      assert {:ok, {_exe, args}} =
               Bwrap.build_command("pwd",
                 workspace_path: workspace,
                 cwd: subdir,
                 executable: bwrap,
                 prlimit_executable: prlimit,
                 limits: :disabled
               )

      assert pair_at?(args, "--chdir", "/workspace/apps/core")
    end

    test "rejects a cwd outside the workspace", %{
      root: root,
      workspace: workspace,
      bwrap: bwrap,
      prlimit: prlimit
    } do
      assert {:error, _reason} =
               Bwrap.build_command("pwd",
                 workspace_path: workspace,
                 cwd: Path.join(root, "outside"),
                 executable: bwrap,
                 prlimit_executable: prlimit,
                 limits: :disabled
               )
    end

    test "rejects a missing workspace and the filesystem root", %{
      root: root,
      bwrap: bwrap,
      prlimit: prlimit
    } do
      base = [
        executable: bwrap,
        prlimit_executable: prlimit,
        limits: :disabled
      ]

      assert {:error, _reason} =
               Bwrap.build_command("pwd", [workspace_path: Path.join(root, "missing")] ++ base)

      assert {:error, _reason} =
               Bwrap.build_command("pwd", [workspace_path: "/"] ++ base)

      assert {:error, _reason} = Bwrap.build_command("pwd", base)
    end

    test "forwards validated env through --setenv", %{
      workspace: workspace,
      bwrap: bwrap,
      prlimit: prlimit
    } do
      assert {:ok, {_exe, args}} =
               Bwrap.build_command("pwd",
                 workspace_path: workspace,
                 executable: bwrap,
                 prlimit_executable: prlimit,
                 limits: :disabled,
                 env: [{"FOO", "bar"}, {"MIX_ENV", "test"}]
               )

      assert setenv?(args, "FOO", "bar")
      assert setenv?(args, "MIX_ENV", "test")
    end
  end

  describe "resource limits" do
    test "wraps bwrap in prlimit with exact default flags", %{
      workspace: workspace,
      bwrap: bwrap,
      prlimit: prlimit
    } do
      assert {:ok, {exe, args}} =
               Bwrap.build_command("pwd",
                 workspace_path: workspace,
                 executable: bwrap,
                 prlimit_executable: prlimit
               )

      assert exe == prlimit

      assert Enum.take(args, 5) == [
               "--as=1073741824",
               "--cpu=120",
               "--nproc=4096",
               "--nofile=1024",
               "--"
             ]

      assert bwrap in args
      assert Enum.take(args, -4) == ["--", "/bin/sh", "-c", "pwd"]
    end

    test "limits: :disabled bypasses prlimit", %{
      workspace: workspace,
      bwrap: bwrap,
      prlimit: prlimit
    } do
      assert {:ok, {exe, args}} =
               Bwrap.build_command("pwd",
                 workspace_path: workspace,
                 executable: bwrap,
                 prlimit_executable: prlimit,
                 limits: :disabled
               )

      assert exe == bwrap
      assert hd(args) == "--unshare-all"
      refute Enum.any?(args, &String.starts_with?(&1, "--as="))
    end

    test "a zero-valued limit disables only that flag", %{
      workspace: workspace,
      bwrap: bwrap,
      prlimit: prlimit
    } do
      assert {:ok, {exe, args}} =
               Bwrap.build_command("pwd",
                 workspace_path: workspace,
                 executable: bwrap,
                 prlimit_executable: prlimit,
                 limits: %{memory_mb: 0, cpu_seconds: 60, pids: 0, open_files: 0}
               )

      assert exe == prlimit
      assert Enum.take(args, 2) == ["--cpu=60", "--"]
      refute Enum.any?(args, &String.starts_with?(&1, "--as="))
      refute Enum.any?(args, &String.starts_with?(&1, "--nproc="))
      refute Enum.any?(args, &String.starts_with?(&1, "--nofile="))
    end

    test "errors when limits are active but prlimit is unavailable", %{
      root: root,
      workspace: workspace,
      bwrap: bwrap
    } do
      missing = Path.join(root, "missing-prlimit")

      assert {:error, {:prlimit_unavailable, ^missing}} =
               Bwrap.build_command("pwd",
                 workspace_path: workspace,
                 executable: bwrap,
                 prlimit_executable: missing
               )
    end

    test "validate_limits/1 succeeds with a reachable prlimit", %{
      root: root,
      prlimit: prlimit
    } do
      assert Bwrap.validate_limits(prlimit_executable: prlimit) == :ok

      assert Bwrap.validate_limits(limits: :disabled, prlimit_executable: Path.join(root, "x")) ==
               :ok

      assert Bwrap.validate_limits(limits: %{pids: 0}, prlimit_executable: Path.join(root, "x")) ==
               :ok
    end

    test "validate_limits/1 fails when active limits lack prlimit", %{root: root} do
      missing = Path.join(root, "missing-prlimit")

      assert Bwrap.validate_limits(prlimit_executable: missing) ==
               {:error, {:prlimit_unavailable, missing}}
    end
  end

  describe "probe/1 and available?/1" do
    test "returns :ok when the probe exits zero", %{bwrap: bwrap} do
      runner = fn _exe, _args, _opts -> {"", 0} end

      assert Bwrap.probe(executable: bwrap, runner: runner) == :ok
    end

    test "returns a probe_failed error with the exit code and output prefix", %{bwrap: bwrap} do
      runner = fn _exe, _args, _opts -> {"bubblewrap exploded", 3} end

      assert {:error, {:probe_failed, 3, prefix}} =
               Bwrap.probe(executable: bwrap, runner: runner)

      assert prefix =~ "bubblewrap exploded"
    end

    test "maps :enoent to :bwrap_missing", %{bwrap: bwrap} do
      runner = fn _exe, _args, _opts -> {:error, :enoent} end

      assert Bwrap.probe(executable: bwrap, runner: runner) == {:error, :bwrap_missing}
    end

    test "missing executable fails probe and build", %{
      root: root,
      workspace: workspace,
      prlimit: prlimit
    } do
      missing = Path.join(root, "missing-bwrap")

      assert Bwrap.probe(executable: missing) == {:error, :bwrap_missing}

      assert {:error, :bwrap_missing} =
               Bwrap.build_command("pwd",
                 workspace_path: workspace,
                 executable: missing,
                 prlimit_executable: prlimit,
                 limits: :disabled
               )
    end

    test "available?/1 caches the probe per executable and reset_probe clears it", %{
      bwrap: bwrap
    } do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      runner = fn _exe, _args, _opts ->
        Agent.update(counter, &(&1 + 1))
        {"", 0}
      end

      Bwrap.reset_probe()

      assert Bwrap.available?(executable: bwrap, runner: runner)
      assert Bwrap.available?(executable: bwrap, runner: runner)
      assert Agent.get(counter, & &1) == 1

      assert Bwrap.reset_probe() == :ok

      assert Bwrap.available?(executable: bwrap, runner: runner)
      assert Agent.get(counter, & &1) == 2
    end

    test "available?/1 returns false for a failing probe", %{bwrap: bwrap} do
      Bwrap.reset_probe()
      runner = fn _exe, _args, _opts -> {"no user namespaces", 1} end

      refute Bwrap.available?(executable: bwrap, runner: runner)
    end
  end

  # --- Helpers ---

  defp fake_executable!(root, name) do
    path = Path.join(root, name)
    File.write!(path, "#!/bin/sh\nexit 0\n")
    File.chmod!(path, 0o755)
    path
  end

  defp existing_system_paths do
    Enum.filter(@system_paths, &File.exists?/1)
  end

  defp pair_at?(args, flag, value) do
    args
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.any?(fn [left, right] -> left == flag and right == value end)
  end

  defp setenv?(args, key, value) do
    args
    |> Enum.chunk_every(3, 1, :discard)
    |> Enum.any?(fn [flag, k, v] -> flag == "--setenv" and k == key and v == value end)
  end
end
