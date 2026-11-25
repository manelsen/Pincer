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

  defmodule ProbeSandboxAdapter do
    @behaviour Sandbox

    @impl true
    def backend_name, do: :probe_sandbox

    @impl true
    def available?, do: false

    @impl true
    def run(_command, _opts), do: {:error, :unavailable}

    @impl true
    def cleanup(_scope_id), do: :ok

    @impl true
    def probe, do: {:error, :nope}
  end

  setup do
    keys = [:sandbox_adapter, :sandbox_adapters]
    previous = Enum.map(keys, &{&1, Application.fetch_env(:pincer, &1)})
    Application.put_env(:pincer, :sandbox_adapter, FakeSandboxAdapter)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:pincer, key, value)
        {key, :error} -> Application.delete_env(:pincer, key)
      end)
    end)

    :ok
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
      assert {:error, {:unknown_sandbox_adapter, nil}} = Sandbox.resolve_adapter(nil)

      assert {:error, {:unknown_sandbox_adapter, "kubernetes"}} =
               Sandbox.resolve_adapter("kubernetes")

      assert {:error, {:unknown_sandbox_adapter, 123}} = Sandbox.resolve_adapter(123)
    end

    test "resolves short names via :sandbox_adapters application config" do
      Application.put_env(:pincer, :sandbox_adapters, %{local: FakeSandboxAdapter})
      assert {:ok, FakeSandboxAdapter} = Sandbox.resolve_adapter(:local)
      assert {:ok, FakeSandboxAdapter} = Sandbox.resolve_adapter("local")
      assert {:error, {:unknown_sandbox_adapter, :docker}} = Sandbox.resolve_adapter(:docker)
      assert {:error, {:unknown_sandbox_adapter, "ssh"}} = Sandbox.resolve_adapter("ssh")
    end

    test "fully qualified module names resolve without the short-name registry" do
      Application.delete_env(:pincer, :sandbox_adapters)

      assert {:ok, Pincer.Adapters.Sandbox.Docker} =
               Sandbox.resolve_adapter("Pincer.Adapters.Sandbox.Docker")

      assert {:error, {:unknown_sandbox_adapter, "docker"}} = Sandbox.resolve_adapter("docker")
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

    test "adapter/0 raises ArgumentError when configured sandbox adapter is missing or invalid" do
      Application.delete_env(:pincer, :sandbox_adapter)
      assert_raise ArgumentError, ~r/sandbox_adapter/, fn -> Sandbox.adapter() end

      Application.put_env(:pincer, :sandbox_adapter, nil)
      assert_raise ArgumentError, ~r/sandbox_adapter/, fn -> Sandbox.adapter() end

      Application.put_env(:pincer, :sandbox_adapter, "kubernetes")
      assert_raise ArgumentError, ~r/sandbox_adapter/, fn -> Sandbox.adapter() end
    end
  end

  describe "probe/0" do
    test "returns :ok when the configured adapter does not export probe/0" do
      assert Sandbox.adapter() == FakeSandboxAdapter
      refute function_exported?(FakeSandboxAdapter, :probe, 0)

      assert Sandbox.probe() == :ok
    end

    test "dispatches to the adapter probe/0 when exported" do
      Application.put_env(:pincer, :sandbox_adapter, ProbeSandboxAdapter)

      assert Sandbox.probe() == {:error, :nope}
    end
  end
end
