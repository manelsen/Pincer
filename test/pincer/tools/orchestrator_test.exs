defmodule Pincer.Adapters.Tools.OrchestratorTest do
  use ExUnit.Case, async: false
  import Mox

  alias Pincer.Adapters.Tools.Orchestrator
  alias Pincer.Core.Orchestration.SubAgent

  setup :set_mox_global

  setup do
    Pincer.LLM.ClientMock
    |> stub(:chat_completion, fn _msgs, _model, _config, _tools ->
      Process.sleep(60)
      {:ok, %{"content" => "SubAgent finished"}}
    end)
    |> stub(:stream_completion, fn _msgs, _model, _config, _tools ->
      Process.sleep(60)
      {:ok, [%{"choices" => [%{"delta" => %{"content" => "SubAgent finished"}}]}]}
    end)

    ws =
      Path.join(
        System.tmp_dir!(),
        "pincer_orchestrator_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(ws)

    sup = start_supervised!(DynamicSupervisor)
    prev_sup = Application.get_env(:pincer, :sub_agent_supervisor)
    Application.put_env(:pincer, :sub_agent_supervisor, sup)

    on_exit(fn ->
      if Process.alive?(sup) do
        for {_, pid, _, _} <- DynamicSupervisor.which_children(sup), is_pid(pid) do
          DynamicSupervisor.terminate_child(sup, pid)
        end
      end

      case prev_sup do
        nil -> Application.delete_env(:pincer, :sub_agent_supervisor)
        v -> Application.put_env(:pincer, :sub_agent_supervisor, v)
      end

      File.rm_rf!(ws)
    end)

    {:ok, %{sup: sup, ws: ws}}
  end

  test "SubAgent uses :temporary restart strategy for DynamicSupervisor" do
    assert SubAgent.child_spec(goal: "x").restart == :temporary
  end

  test "execute/2 starts SubAgent under DynamicSupervisor", %{sup: sup, ws: ws} do
    assert {:ok, msg} =
             Orchestrator.execute(
               %{"goal" => "Audit workspace"},
               %{"session_id" => "parent_sess", "workspace_path" => ws}
             )

    assert msg =~ "Sub-Agent detached successfully. ID: agent_"

    children = DynamicSupervisor.which_children(sup)
    assert [{:undefined, pid, :worker, [SubAgent]}] = children
    assert Process.alive?(pid)

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    assert DynamicSupervisor.which_children(sup) == []
  end

  test "execute/2 returns error when goal is missing" do
    assert {:error, msg} = Orchestrator.execute(%{}, %{})
    assert msg =~ "goal"
  end
end
