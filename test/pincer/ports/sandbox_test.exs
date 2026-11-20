defmodule Pincer.Ports.SandboxTest do
  use ExUnit.Case, async: false

  alias Pincer.Ports.Sandbox

  defmodule FakeSandboxAdapter do
    @behaviour Sandbox

    @impl true
    def backend_name, do: :fake_sandbox

    @impl true
    def available?, do: true

    @impl true
    def run(command, opts) do
      if notify_pid = Keyword.get(opts, :notify_pid) do
        send(notify_pid, {:fake_sandbox_run, command, opts})
      end

      {:ok,
       %{
         output: "executed: #{command}",
         exit_code: 0,
         backend: :fake_sandbox,
         metadata: %{cwd: Keyword.get(opts, :cwd)}
       }}
    end

    @impl true
    def cleanup(scope_id) do
      if pid = Process.get(:fake_sandbox_notify_pid) do
        send(pid, {:fake_sandbox_cleanup, scope_id})
      end

      :ok
    end
  end

  setup do
    previous = Application.get_env(:pincer, :sandbox_adapter)
    Application.put_env(:pincer, :sandbox_adapter, FakeSandboxAdapter)

    on_exit(fn ->
      if previous do
        Application.put_env(:pincer, :sandbox_adapter, previous)
      else
        Application.delete_env(:pincer, :sandbox_adapter)
      end
    end)

    :ok
  end

  describe "validate_env/1" do
    test "accepts nil, empty list, keyword-like tuples, and string maps" do
      assert {:ok, []} = Sandbox.validate_env(nil)
      assert {:ok, []} = Sandbox.validate_env([])

      assert {:ok, [{"FOO", "bar"}, {"BAZ_1", "qux"}]} =
               Sandbox.validate_env([{"FOO", "bar"}, {"BAZ_1", "qux"}])

      assert {:ok, normalized} = Sandbox.validate_env(%{"FOO_1" => "val", "BAR" => "2"})
      assert Enum.sort(normalized) == [{"BAR", "2"}, {"FOO_1", "val"}]
    end

    test "rejects dangerous loader and shell startup environment variables" do
      for forbidden <- [
            "LD_PRELOAD",
            "LD_LIBRARY_PATH",
            "DYLD_INSERT_LIBRARIES",
            "DYLD_LIBRARY_PATH",
            "BASH_ENV",
            "ENV",
            "IFS"
          ] do
        assert {:error, {:forbidden_env, ^forbidden}} =
                 Sandbox.validate_env([{forbidden, "/tmp/evil.so"}])
      end
    end

    test "rejects malformed variable names and non-binary entries" do
      for bad_key <- ["", "BAD-KEY", "123", "FOO=BAR", "a;b", "HAS SPACE"] do
        assert {:error, {:invalid_env_key, ^bad_key}} = Sandbox.validate_env([{bad_key, "ok"}])
      end

      assert {:error, :invalid_env_entry} = Sandbox.validate_env([{:ATOM_KEY, "val"}])
      assert {:error, :invalid_env_entry} = Sandbox.validate_env([{"VALID_KEY", 123}])
      assert {:error, :invalid_env_entry} = Sandbox.validate_env(["NOT_A_TUPLE"])
    end
  end

  describe "resolve_adapter/1" do
    test "resolves short names, atoms, and known module strings" do
      assert {:ok, Pincer.Adapters.Sandbox.Local} = Sandbox.resolve_adapter("local")
      assert {:ok, Pincer.Adapters.Sandbox.Local} = Sandbox.resolve_adapter(:local)
      assert {:ok, Pincer.Adapters.Sandbox.Docker} = Sandbox.resolve_adapter("docker")
      assert {:ok, Pincer.Adapters.Sandbox.Docker} = Sandbox.resolve_adapter(:docker)
      assert {:ok, Pincer.Adapters.Sandbox.SSH} = Sandbox.resolve_adapter("ssh")
      assert {:ok, Pincer.Adapters.Sandbox.SSH} = Sandbox.resolve_adapter(:ssh)

      assert {:ok, FakeSandboxAdapter} = Sandbox.resolve_adapter(FakeSandboxAdapter)

      assert {:ok, Pincer.Adapters.Sandbox.Docker} =
               Sandbox.resolve_adapter("Pincer.Adapters.Sandbox.Docker")
    end

    test "rejects unknown adapter specs" do
      assert {:error, {:unknown_sandbox_adapter, "kubernetes"}} =
               Sandbox.resolve_adapter("kubernetes")

      assert {:error, {:unknown_sandbox_adapter, 123}} = Sandbox.resolve_adapter(123)
    end
  end

  describe "dispatcher functions" do
    test "dispatches backend_name/0, available?/0, run/2, and cleanup/1 to configured adapter" do
      Process.put(:fake_sandbox_notify_pid, self())

      assert Sandbox.adapter() == FakeSandboxAdapter
      assert Sandbox.backend_name() == :fake_sandbox
      assert Sandbox.available?() == true

      assert {:ok, %{output: "executed: ls -la", exit_code: 0, backend: :fake_sandbox}} =
               Sandbox.run("ls -la", cwd: "/tmp", notify_pid: self())

      assert_received {:fake_sandbox_run, "ls -la", opts}
      assert Keyword.get(opts, :cwd) == "/tmp"

      assert :ok = Sandbox.cleanup("scope-123")
      assert_received {:fake_sandbox_cleanup, "scope-123"}
    after
      Process.delete(:fake_sandbox_notify_pid)
    end
  end

  describe "backend_config/1 and run_with_timeout/2" do
    test "reads configured backend options ignoring unknown string keys safely" do
      previous_cfg = Application.get_env(:pincer, :sandbox)

      on_exit(fn ->
        if previous_cfg do
          Application.put_env(:pincer, :sandbox, previous_cfg)
        else
          Application.delete_env(:pincer, :sandbox)
        end
      end)

      Application.put_env(:pincer, :sandbox, %{
        "docker" => %{"image" => "elixir:1.18", "nonexistent_atom_key_xyz_987" => "ignored"}
      })

      cfg = Sandbox.backend_config(:docker)
      assert Keyword.get(cfg, :image) == "elixir:1.18"
      assert Sandbox.backend_config(:ssh) == []
    end

    test "enforces timeout and returns task exit errors cleanly" do
      assert {:ok, :done} = Sandbox.run_with_timeout(fn -> :done end, 1_000)
      assert {:ok, :no_timer} = Sandbox.run_with_timeout(fn -> :no_timer end, :infinity)

      assert {:error, :timeout} =
               Sandbox.run_with_timeout(fn -> Process.sleep(200) end, 25)
    end
  end
end
