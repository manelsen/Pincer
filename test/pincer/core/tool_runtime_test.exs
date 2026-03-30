defmodule Pincer.Core.ToolRuntimeTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.ToolRuntime

  defmodule RegistryOkStub do
    def execute_tool("web_fetch", _args, _context), do: {:ok, "fetched"}
    def execute_tool("safe_shell", _args, _context), do: {:ok, "sensitive output 123"}
    def execute_tool("file_system", _args, _context), do: {:ok, "wrote file /tmp/x"}
    def execute_tool(_name, _args, _context), do: {:ok, "ok"}
  end

  defmodule RegistrySlowStub do
    def execute_tool(_name, _args, _context) do
      Process.sleep(50)
      {:ok, "late"}
    end
  end

  test "classify/1 defines all four risk classes" do
    assert {:ok, :pure} = ToolRuntime.classify("get_code_skeleton")
    assert {:ok, :read} = ToolRuntime.classify("web_fetch")
    assert {:ok, :guarded_write} = ToolRuntime.classify("file_system")
    assert {:ok, :privileged} = ToolRuntime.classify("safe_shell")
  end

  test "execute enforces timeout and cancellation metadata by class" do
    assert {:error, :timeout, meta} =
             ToolRuntime.execute("web_fetch", %{}, %{}, RegistrySlowStub, timeout_ms: 5)

    assert meta.cancelled? == true
    assert meta.class == :read
  end

  test "execute returns success metadata when tool finishes in time" do
    assert {:ok, "fetched", meta} = ToolRuntime.execute("web_fetch", %{}, %{}, RegistryOkStub)
    assert meta.class == :read
    assert meta.cancelled? == false
    assert is_integer(meta.timeout_ms)
  end

  test "privileged tools require explicit approval before execution" do
    assert {:error, {:approval_required, details}, meta} =
             ToolRuntime.execute("safe_shell", %{"command" => "ls"}, %{}, RegistryOkStub)

    assert details.tool == "safe_shell"
    assert details.class == :privileged
    assert details.reason == :privileged_tool
    assert meta.class == :privileged
  end

  test "privileged tools execute when approval is granted" do
    assert {:ok, "sensitive output 123", meta} =
             ToolRuntime.execute("safe_shell", %{"command" => "ls"}, %{}, RegistryOkStub,
               approval_granted: true
             )

    assert meta.class == :privileged
    assert meta.cancelled? == false
  end

  test "sanitize_summary applies class-specific sanitization" do
    assert ToolRuntime.sanitize_summary(
             "get_code_skeleton",
             "very long " <> String.duplicate("a", 600)
           ) =~
             "very long"

    assert ToolRuntime.sanitize_summary("file_system", "wrote /tmp/hello") =~ "[guarded]"

    assert ToolRuntime.sanitize_summary("safe_shell", "secret token 123") ==
             "[privileged] output redacted"
  end
end
