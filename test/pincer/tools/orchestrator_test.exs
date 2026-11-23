defmodule Pincer.Adapters.Tools.OrchestratorTest do
  use ExUnit.Case, async: false
  import Mox

  alias Pincer.Adapters.Tools.BlackboardReader
  alias Pincer.Adapters.Tools.Orchestrator
  alias Pincer.Core.Orchestration.Blackboard
  alias Pincer.Core.Orchestration.SubAgent
  alias Pincer.Core.Orchestration.SubAgentRegistry

  defmodule RunInfoStorageStub do
    def load_checkpoint(session_id, opts) do
      send(Application.fetch_env!(:pincer, :orchestrator_run_info_pid), {:load, session_id, opts})

      {:ok,
       %Pincer.Storage.Checkpoint{
         id: Pincer.Infra.UUID.generate(),
         session_id: session_id,
         status: "finished",
         step_count: 7,
         metadata: %{"kind" => "subagent", "goal" => "Audit", "result" => "all clear"},
         inserted_at: ~U[2026-01-01 00:00:00Z],
         updated_at: ~U[2026-01-01 00:01:00Z]
       }}
    end

    def save_checkpoint(session_id, checkpoint) do
      send(Application.fetch_env!(:pincer, :orchestrator_run_info_pid), {:save, session_id})
      {:ok, checkpoint}
    end
  end

  setup :set_mox_global

  setup do
    Pincer.LLM.ClientMock
    |> stub(:chat_completion, fn _msgs, _model, _config, _tools ->
      Process.sleep(300)
      {:ok, %{"content" => "SubAgent finished"}}
    end)
    |> stub(:stream_completion, fn _msgs, _model, _config, _tools ->
      Process.sleep(300)
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

  test "spec advertises per-run model overrides, action, and agent_id" do
    spec = Orchestrator.spec()
    props = spec.parameters.properties

    assert spec.parameters.required == []
    assert props[:goal].type == "string"
    assert props[:provider].type == "string"
    assert props[:model].type == "string"
    assert props[:thinking_level].type == "string"
    assert props[:action].type == "string"
    assert props[:agent_id].type == "string"
  end

  test "execute/2 forwards a complete model override into the SubAgent state", %{ws: ws} do
    assert {:ok, msg} =
             Orchestrator.execute(
               %{
                 "goal" => "Use a specific model",
                 "provider" => "openai",
                 "model" => "gpt-5",
                 "thinking_level" => "high"
               },
               %{"session_id" => "parent_model", "workspace_path" => ws}
             )

    id = agent_id_from(msg)

    assert {:ok, pid} = await_agent(SubAgentRegistry, id)

    assert :sys.get_state(pid).model_override == %{
             provider: "openai",
             model: "gpt-5",
             thinking_level: "high"
           }
  end

  test "execute/2 ignores an incomplete model override", %{ws: ws} do
    assert {:ok, msg} =
             Orchestrator.execute(
               %{"goal" => "No model here", "provider" => "openai"},
               %{"session_id" => "parent_partial_model", "workspace_path" => ws}
             )

    id = agent_id_from(msg)

    assert {:ok, pid} = await_agent(SubAgentRegistry, id)
    assert :sys.get_state(pid).model_override == nil
  end

  test "global limit rejects before starting a child", %{sup: sup, ws: ws} do
    prev = Application.get_env(:pincer, :max_subagents)
    Application.put_env(:pincer, :max_subagents, 0)

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:pincer, :max_subagents)
        value -> Application.put_env(:pincer, :max_subagents, value)
      end
    end)

    before_children = DynamicSupervisor.which_children(sup)

    assert {:error, msg} =
             Orchestrator.execute(
               %{"goal" => "Must not start"},
               %{"session_id" => unique_session("global"), "workspace_path" => ws}
             )

    assert msg =~ "Sub-agent limit reached"
    assert DynamicSupervisor.which_children(sup) == before_children
  end

  test "per-session limit rejects before starting a child and releases after exit", %{
    sup: sup,
    ws: ws
  } do
    prev_global = Application.get_env(:pincer, :max_subagents)
    prev_session = Application.get_env(:pincer, :max_subagents_per_session)

    Application.put_env(:pincer, :max_subagents, 100)
    Application.put_env(:pincer, :max_subagents_per_session, 1)

    on_exit(fn ->
      restore_env(:max_subagents, prev_global)
      restore_env(:max_subagents_per_session, prev_session)
    end)

    session = unique_session("session_limit")

    assert {:ok, first} =
             Orchestrator.execute(
               %{"goal" => "First"},
               %{"session_id" => session, "workspace_path" => ws}
             )

    first_id = agent_id_from(first)
    before_children = length(DynamicSupervisor.which_children(sup))

    assert {:error, msg} =
             Orchestrator.execute(
               %{"goal" => "Second"},
               %{"session_id" => session, "workspace_path" => ws}
             )

    assert msg =~ "Sub-agent limit reached"
    assert length(DynamicSupervisor.which_children(sup)) == before_children

    assert {:ok, _pid} = await_agent(SubAgentRegistry, first_id)

    wait_until(fn -> SubAgentRegistry.count_for(session) == 0 end)

    assert {:ok, third} =
             Orchestrator.execute(
               %{"goal" => "Third after release"},
               %{"session_id" => session, "workspace_path" => ws}
             )

    assert agent_id_from(third) =~ ~r/^agent_/

    wait_until(fn -> SubAgentRegistry.count_for(session) == 0 end)
  end

  test "root dispatch records depth 1 and the root session id", %{ws: ws} do
    root = unique_session("root_dispatch")

    assert {:ok, msg} =
             Orchestrator.execute(
               %{"goal" => "Root dispatch"},
               %{"session_id" => root, "workspace_path" => ws}
             )

    id = agent_id_from(msg)
    assert {:ok, pid} = await_agent(SubAgentRegistry, id)

    state = :sys.get_state(pid)
    assert state.subagent_depth == 1
    assert state.root_session_id == root
    assert state.parent_session_id == root

    wait_until(fn -> SubAgentRegistry.count_for(root) == 0 end)
  end

  test "a depth-1 context may dispatch depth 2", %{ws: ws} do
    root = unique_session("root_nested")
    depth_one_session = unique_session("agent_depth_one")

    assert {:ok, msg} =
             Orchestrator.execute(
               %{"goal" => "Nested dispatch"},
               %{
                 "session_id" => depth_one_session,
                 "subagent_depth" => 1,
                 "root_session_id" => root,
                 "workspace_path" => ws
               }
             )

    id = agent_id_from(msg)
    assert {:ok, pid} = await_agent(SubAgentRegistry, id)

    state = :sys.get_state(pid)
    assert state.subagent_depth == 2
    assert state.root_session_id == root
    assert state.parent_session_id == depth_one_session
    assert SubAgentRegistry.count_for(root) == 1

    wait_until(fn -> SubAgentRegistry.count_for(root) == 0 end)
  end

  test "rejects a dispatch at the depth cap before reserving or starting a child", %{
    sup: sup,
    ws: ws
  } do
    prev = Application.get_env(:pincer, :max_subagent_depth)
    Application.put_env(:pincer, :max_subagent_depth, 2)

    on_exit(fn -> restore_env(:max_subagent_depth, prev) end)

    root = unique_session("root_depth_cap")
    before_children = length(DynamicSupervisor.which_children(sup))

    assert {:error, msg} =
             Orchestrator.execute(
               %{"goal" => "Too deep"},
               %{
                 "session_id" => unique_session("agent_at_cap"),
                 "subagent_depth" => 2,
                 "root_session_id" => root,
                 "workspace_path" => ws
               }
             )

    assert msg =~ "depth limit"
    assert msg =~ "depth 2"
    assert msg =~ "cap 2"
    assert length(DynamicSupervisor.which_children(sup)) == before_children
    assert SubAgentRegistry.count_for(root) == 0
  end

  test "charges the per-session cap against the root session id across the tree", %{
    sup: sup,
    ws: ws
  } do
    prev_global = Application.get_env(:pincer, :max_subagents)
    prev_session = Application.get_env(:pincer, :max_subagents_per_session)
    prev_depth = Application.get_env(:pincer, :max_subagent_depth)

    Application.put_env(:pincer, :max_subagents, 100)
    Application.put_env(:pincer, :max_subagents_per_session, 1)
    Application.put_env(:pincer, :max_subagent_depth, 2)

    on_exit(fn ->
      restore_env(:max_subagents, prev_global)
      restore_env(:max_subagents_per_session, prev_session)
      restore_env(:max_subagent_depth, prev_depth)
    end)

    root = unique_session("root_shared_cap")

    assert {:ok, _msg} =
             Orchestrator.execute(
               %{"goal" => "Root child"},
               %{"session_id" => root, "workspace_path" => ws}
             )

    assert SubAgentRegistry.count_for(root) == 1
    before_children = length(DynamicSupervisor.which_children(sup))

    assert {:error, msg} =
             Orchestrator.execute(
               %{"goal" => "Nested child"},
               %{
                 "session_id" => unique_session("agent_tree_child"),
                 "subagent_depth" => 1,
                 "root_session_id" => root,
                 "workspace_path" => ws
               }
             )

    assert msg =~ "session cap of 1"
    assert length(DynamicSupervisor.which_children(sup)) == before_children
    assert SubAgentRegistry.count_for(root) == 1

    wait_until(fn -> SubAgentRegistry.count_for(root) == 0 end)
  end

  test "tree token budget rejects the next dispatch before starting a child", %{sup: sup, ws: ws} do
    prev_global = Application.get_env(:pincer, :max_subagents)
    prev_session = Application.get_env(:pincer, :max_subagents_per_session)
    prev_tree_tokens = Application.get_env(:pincer, :max_subagent_tree_tokens)

    Application.put_env(:pincer, :max_subagents, 100)
    Application.put_env(:pincer, :max_subagents_per_session, :infinity)
    Application.put_env(:pincer, :max_subagent_tree_tokens, 10)

    on_exit(fn ->
      restore_env(:max_subagents, prev_global)
      restore_env(:max_subagents_per_session, prev_session)
      restore_env(:max_subagent_tree_tokens, prev_tree_tokens)
    end)

    root = unique_session("tree_token")

    assert {:ok, first} =
             Orchestrator.execute(
               %{"goal" => "First in tree"},
               %{"session_id" => root, "workspace_path" => ws}
             )

    first_id = agent_id_from(first)
    on_exit(fn -> SubAgentRegistry.release(first_id) end)

    assert :ok = SubAgentRegistry.add_usage(root, 10)
    before_children = child_pids(sup)

    assert {:error, message} =
             Orchestrator.execute(
               %{"goal" => "Must not start"},
               %{"session_id" => root, "workspace_path" => ws}
             )

    assert message =~ "tree token budget"
    assert message =~ "cap 10 tokens"
    assert MapSet.subset?(child_pids(sup), before_children)

    wait_until(fn -> SubAgentRegistry.count_for(root) == 0 end)
    assert SubAgentRegistry.tree_usage(root) == :error
  end

  test "tree deadline rejects the next dispatch before starting a child", %{sup: sup, ws: ws} do
    prev_global = Application.get_env(:pincer, :max_subagents)
    prev_session = Application.get_env(:pincer, :max_subagents_per_session)
    prev_tree_tokens = Application.get_env(:pincer, :max_subagent_tree_tokens)
    prev_tree_ms = Application.get_env(:pincer, :max_subagent_tree_ms)
    original_now_fun = registry_now_fun()

    Application.put_env(:pincer, :max_subagents, 100)
    Application.put_env(:pincer, :max_subagents_per_session, :infinity)
    Application.put_env(:pincer, :max_subagent_tree_tokens, :infinity)
    Application.put_env(:pincer, :max_subagent_tree_ms, 1_000)

    clock = start_supervised!({Agent, fn -> 0 end})
    inject_clock!(fn -> Agent.get(clock, & &1) end)

    on_exit(fn ->
      restore_env(:max_subagents, prev_global)
      restore_env(:max_subagents_per_session, prev_session)
      restore_env(:max_subagent_tree_tokens, prev_tree_tokens)
      restore_env(:max_subagent_tree_ms, prev_tree_ms)
      restore_now_fun(original_now_fun)
    end)

    root = unique_session("tree_deadline")

    assert {:ok, first} =
             Orchestrator.execute(
               %{"goal" => "First in tree"},
               %{"session_id" => root, "workspace_path" => ws}
             )

    first_id = agent_id_from(first)
    on_exit(fn -> SubAgentRegistry.release(first_id) end)

    Agent.update(clock, fn _ -> 1_000 end)
    before_children = child_pids(sup)

    assert {:error, message} =
             Orchestrator.execute(
               %{"goal" => "Must not start"},
               %{"session_id" => root, "workspace_path" => ws}
             )

    assert message =~ "tree deadline"
    assert message =~ "cap 1000 ms"
    assert MapSet.subset?(child_pids(sup), before_children)

    wait_until(fn -> SubAgentRegistry.count_for(root) == 0 end)
    assert SubAgentRegistry.tree_usage(root) == :error
  end

  test "action status formats the durable run record", %{} do
    prev = Application.get_env(:pincer, :storage_adapter)

    Application.put_env(:pincer, :storage_adapter, RunInfoStorageStub)
    Application.put_env(:pincer, :orchestrator_run_info_pid, self())

    on_exit(fn ->
      restore_env(:storage_adapter, prev)

      case Application.get_env(:pincer, :orchestrator_run_info_pid) do
        nil -> :ok
        _ -> Application.delete_env(:pincer, :orchestrator_run_info_pid)
      end
    end)

    assert {:ok, report} =
             Orchestrator.execute(%{"action" => "status", "agent_id" => "agent_status_1"}, %{})

    assert report =~ "agent_status_1"
    assert report =~ "finished"
    assert report =~ "7"
    assert report =~ "all clear"

    assert_received {:load, "agent_status_1", opts}
    assert Enum.sort(opts[:status]) == ~w(completed failed finished interrupted paused running)
  end

  describe "read_blackboard" do
    setup do
      Blackboard.reset()
      on_exit(fn -> Blackboard.reset() end)
      :ok
    end

    test "returns only the most recent messages in chronological order when limited" do
      post_messages(12)

      assert {:ok, output} = BlackboardReader.execute(%{"limit" => 5})

      assert message_contents(output) == Enum.map(8..12, &"message #{&1}")
    end

    test "defaults to the last 10 messages when limit is missing" do
      post_messages(12)

      assert {:ok, output} = BlackboardReader.execute(%{})

      assert message_contents(output) == Enum.map(3..12, &"message #{&1}")
    end

    test "clamps limits above 100" do
      post_messages(105)

      assert {:ok, output} = BlackboardReader.execute(%{"limit" => 1000})

      contents = message_contents(output)
      assert length(contents) == 100
      assert List.first(contents) == "message 6"
      assert List.last(contents) == "message 105"
    end

    test "rejects a limit that is not a positive integer" do
      error = "read_blackboard limit must be a positive integer (max 100)"

      assert {:error, ^error} = BlackboardReader.execute(%{"limit" => 0})
      assert {:error, ^error} = BlackboardReader.execute(%{"limit" => "5"})
    end

    test "reports an empty blackboard" do
      assert {:ok, "Blackboard is empty."} = BlackboardReader.execute(%{"limit" => 5})
    end
  end

  defp child_pids(sup) do
    sup
    |> DynamicSupervisor.which_children()
    |> Enum.map(fn {_id, pid, _type, _modules} -> pid end)
    |> MapSet.new()
  end

  defp inject_clock!(fun) do
    :sys.replace_state(SubAgentRegistry, &Map.put(&1, :now_fun, fun))
  end

  defp registry_now_fun do
    SubAgentRegistry
    |> :sys.get_state()
    |> Map.get(:now_fun, fn -> System.monotonic_time(:millisecond) end)
  end

  defp restore_now_fun(fun) do
    if Process.whereis(SubAgentRegistry) do
      :sys.replace_state(SubAgentRegistry, &Map.put(&1, :now_fun, fun))
    end

    :ok
  end

  defp post_messages(count) do
    for i <- 1..count do
      Blackboard.post("agent_read", "message #{i}", nil, scope: :global)
    end

    Blackboard.wait_for_journal()
  end

  defp message_contents(output) do
    output
    |> String.split("\n")
    |> Enum.map(fn line ->
      case Regex.run(~r/\]: (.*)$/, line) do
        [_, content] -> content
        _ -> line
      end
    end)
  end

  defp unique_session(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  defp agent_id_from(message) do
    case Regex.run(~r/ID: (agent_[a-f0-9]+)/, message) do
      [_, id] -> id
      _ -> flunk("no agent id in #{inspect(message)}")
    end
  end

  defp await_agent(registry, id, attempts \\ 100) do
    case registry.lookup(id) do
      {:ok, pid} ->
        {:ok, pid}

      :error when attempts > 0 ->
        Process.sleep(5)
        await_agent(registry, id, attempts - 1)

      :error ->
        {:error, :not_found}
    end
  end

  defp wait_until(fun, attempts \\ 200) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("condition not met in time")

      true ->
        Process.sleep(5)
        wait_until(fun, attempts - 1)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:pincer, key)
  defp restore_env(key, value), do: Application.put_env(:pincer, key, value)
end
