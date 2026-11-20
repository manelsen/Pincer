defmodule Pincer.Core.Executor.ToolRunnerTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.Executor.Ctx
  alias Pincer.Core.Executor.ToolRunner

  defmodule RegistryStub do
    @behaviour Pincer.Ports.ToolRegistry

    @impl true
    def list_tools, do: []

    @impl true
    def execute_tool("ok_tool", args, ctx) do
      {:ok, "ok:#{args["v"]}:#{ctx["workspace_path"]}"}
    end

    def execute_tool("slow_tool", args, _ctx) do
      Process.sleep(100)
      {:ok, "slow:#{args["v"]}"}
    end

    def execute_tool("fail_tool", _args, _ctx) do
      {:error, :boom}
    end

    def execute_tool("crash_tool", _args, _ctx) do
      raise "kaboom"
    end

    def execute_tool("approval_tool", %{"approved" => true}, _ctx) do
      {:ok, "approved-run"}
    end

    def execute_tool("approval_tool", _args, _ctx) do
      {:error,
       {:approval_required,
        %{
          tool: "approval_tool",
          command: "rm -rf /tmp/x",
          args: %{"approved" => true},
          class: :privileged
        }}}
    end

    def execute_tool("huge_tool", _args, _ctx) do
      {:ok, String.duplicate("x", 40_000)}
    end
  end

  defmodule StorageSpy do
    def save_tool_error(name, args, reason) do
      send(self(), {:saved_tool_error, name, args, reason})
      {:ok, :saved}
    end
  end

  test "executes a single tool sequentially without touching process dictionary and sends sme_tool_use" do
    workspace = tmp_dir!()

    ctx =
      Ctx.new(self(), "runner_single",
        workspace_path: workspace,
        tool_registry: RegistryStub,
        storage: StorageSpy,
        trace_events?: true
      )

    call = %{
      "id" => "c1",
      "function" => %{"name" => "ok_tool", "arguments" => ~s({"v":"1"})}
    }

    {results, updated_ctx} = ToolRunner.execute_batch([call], ctx)

    assert [
             %{
               "role" => "tool",
               "tool_call_id" => "c1",
               "name" => "ok_tool",
               "content" => "ok:1:" <> ^workspace
             }
           ] = results

    assert updated_ctx.consecutive_errors == 0
    assert Process.get(:workspace_path) == nil
    assert Process.get(:executor_deps) == nil

    assert_received {:sme_tool_use, ["ok_tool: 1"]}
    assert_received {:executor_trace_step, :tool, "tool_invoked", %{tool: "ok_tool"}}
    assert_received {:executor_trace_step, :tool, "tool_audit", %{status: :ok}}
    assert_received {:executor_trace_step, :tool, "tool_result", %{tool: "ok_tool"}}
    refute_received {:executor_status, _}
  end

  test "executes multiple tools in parallel and folds trace steps and consecutive errors" do
    workspace = tmp_dir!()

    ctx =
      Ctx.new(self(), "runner_parallel",
        workspace_path: workspace,
        tool_registry: RegistryStub,
        storage: StorageSpy,
        trace_events?: true
      )

    calls = [
      %{"id" => "c1", "function" => %{"name" => "slow_tool", "arguments" => ~s({"v":"1"})}},
      %{"id" => "c2", "function" => %{"name" => "slow_tool", "arguments" => ~s({"v":"2"})}},
      %{"id" => "c3", "function" => %{"name" => "fail_tool", "arguments" => "{}"}}
    ]

    {results, updated_ctx} = ToolRunner.execute_batch(calls, ctx)

    assert length(results) == 3
    assert Enum.at(results, 0)["content"] == "slow:1"
    assert Enum.at(results, 1)["content"] == "slow:2"
    assert Enum.at(results, 2)["content"] == "Error: :boom"

    assert_received {:executor_status, status}
    assert status =~ "Orquestração Paralela"
    assert updated_ctx.consecutive_errors == 1
    assert length(updated_ctx.trace.steps) == 9
  end

  test "captures repeated consecutive errors at threshold 3 via ctx.deps.storage" do
    ctx =
      Ctx.new(self(), "runner_errors",
        workspace_path: tmp_dir!(),
        tool_registry: RegistryStub,
        storage: StorageSpy
      )
      |> Map.put(:consecutive_errors, 2)

    call = %{"id" => "c_err", "function" => %{"name" => "fail_tool", "arguments" => "{}"}}
    {_results, updated_ctx} = ToolRunner.execute_batch([call], ctx)

    assert updated_ctx.consecutive_errors == 3
    assert_received {:saved_tool_error, "fail_tool", %{}, ":boom"}
  end

  test "handles approval timeout, crashes, truncation, invalid call, and markdown artifacts" do
    workspace = tmp_dir!()
    File.write!(Path.join(workspace, "PLAN.md"), "# Plan")
    File.write!(Path.join(workspace, "BOOTSTRAP.md"), "# Bootstrap")

    ctx =
      Ctx.new(self(), "runner_edge",
        workspace_path: workspace,
        tool_registry: RegistryStub,
        storage: StorageSpy,
        approval_timeout_ms: 25
      )

    calls = [
      %{"id" => "c_app", "function" => %{"name" => "approval_tool", "arguments" => "{}"}},
      %{"id" => "c_crash", "function" => %{"name" => "crash_tool", "arguments" => "{}"}},
      %{"id" => "c_huge", "function" => %{"name" => "huge_tool", "arguments" => "{}"}},
      :not_a_map
    ]

    {results, _updated_ctx} = ToolRunner.execute_batch(calls, ctx)

    assert Enum.at(results, 0)["content"] =~ "timed out waiting for approval"
    assert Enum.at(results, 1)["content"] =~ "Parallel execution error"
    assert Enum.at(results, 1)["content"] =~ "kaboom"
    assert Enum.at(results, 2)["content"] =~ "resultado truncado"
    assert Enum.at(results, 3)["content"] == "Error: invalid tool call payload."

    assert_received {:executor_status, "⚡" <> _}
    assert_received {:executor_status, md_notice}
    assert md_notice =~ "PLAN.md"
    refute md_notice =~ "BOOTSTRAP.md"
  end

  test "handles approval granted and denied in sequential tool execution" do
    session_id = "runner_approval_#{System.unique_integer([:positive])}"
    Pincer.Infra.PubSub.subscribe("session:#{session_id}")
    on_exit(fn -> Pincer.Infra.PubSub.unsubscribe("session:#{session_id}") end)

    ctx =
      Ctx.new(self(), session_id,
        workspace_path: tmp_dir!(),
        tool_registry: RegistryStub,
        storage: StorageSpy,
        trace_events?: true
      )

    call = %{"id" => "c_ok", "function" => %{"name" => "approval_tool", "arguments" => "{}"}}

    test_pid = self()

    task =
      Task.async(fn ->
        ToolRunner.execute_batch([call], %{ctx | session_pid: test_pid})
      end)

    assert_receive {:approval_required, "c_ok", "rm -rf /tmp/x"}, 1_000
    send(task.pid, {:tool_approval_result, "c_ok", :approved})

    {[approved_msg], _ctx} = Task.await(task, 2_000)
    assert approved_msg["content"] == "approved-run"

    task2 =
      Task.async(fn ->
        ToolRunner.execute_batch([call], %{ctx | session_pid: test_pid})
      end)

    assert_receive {:approval_required, "c_ok", "rm -rf /tmp/x"}, 1_000
    send(task2.pid, {:tool_approval_result, "c_ok", :rejected})

    {[denied_msg], _ctx} = Task.await(task2, 2_000)
    assert denied_msg["content"] =~ "Approval denied for approval_tool"
  end

  defp tmp_dir! do
    tmp = Path.join(System.tmp_dir!(), "pincer_runner_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    tmp
  end
end
