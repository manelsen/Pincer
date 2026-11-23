defmodule Pincer.Core.Orchestration.SubAgentTest do
  use ExUnit.Case, async: false

  alias Pincer.Core.Orchestration.Blackboard
  alias Pincer.Core.Orchestration.SubAgent
  alias Pincer.Infra.PubSub

  defmodule ToolRegistryStub do
    @behaviour Pincer.Ports.ToolRegistry
    @impl true
    def list_tools, do: []
    @impl true
    def execute_tool(_name, _args, _context), do: {:error, :not_implemented}
  end

  defmodule StorageStub do
    def list_recent_learnings(_limit), do: []
    def search_messages(_q, _limit), do: {:ok, []}
    def search_documents(_q, _limit), do: {:ok, []}
    def search_documents(_q, _limit, _opts), do: {:ok, []}
    def search_similar(_t, _v, _limit), do: {:ok, []}
    def search_graph_history(_q, _limit), do: {:ok, []}
  end

  defmodule LLMStub do
    @behaviour Pincer.Ports.LLM

    def put_mode(mode) do
      agent = Application.fetch_env!(:pincer, :sub_agent_test_agent)
      Agent.update(agent, fn _ -> mode end)
    end

    defp mode do
      agent = Application.fetch_env!(:pincer, :sub_agent_test_agent)
      Agent.get(agent, & &1)
    end

    @impl true
    def stream_completion(_messages, opts) do
      notify_opts(opts)

      case mode() do
        :ok -> {:ok, [%{"choices" => [%{"delta" => %{"content" => "Task complete"}}]}], nil}
        :error -> {:error, :boom}
        :crash -> raise "kaboom"
        :hold -> hold_stream()
      end
    end

    @impl true
    def chat_completion(_messages, opts) do
      notify_opts(opts)

      case mode() do
        :ok -> {:ok, %{"role" => "assistant", "content" => "Task complete"}, nil}
        :error -> {:error, :boom}
        :crash -> raise "kaboom"
        :hold -> hold_chat()
      end
    end

    defp hold_stream do
      hold()

      {:ok, [%{"choices" => [%{"delta" => %{"content" => "Task complete"}}]}], nil}
    end

    defp hold_chat do
      hold()

      {:ok, %{"role" => "assistant", "content" => "Task complete"}, nil}
    end

    defp hold do
      pid = Application.fetch_env!(:pincer, :sub_agent_test_hold_pid)
      send(pid, {:llm_holding, self()})

      receive do
        :release_llm -> :ok
      after
        10_000 -> :ok
      end
    end

    defp notify_opts(opts) do
      case Application.get_env(:pincer, :sub_agent_test_llm_opts_pid) do
        pid when is_pid(pid) -> send(pid, {:llm_opts, opts})
        _ -> :ok
      end
    end

    @impl true
    def list_providers, do: []
    @impl true
    def list_models(_provider_id), do: []
    @impl true
    def transcribe_audio(_file_path, _opts), do: {:error, :not_implemented}
    @impl true
    def provider_config(_provider_id), do: nil
  end

  defmodule RunInfoStorageStub do
    def load_checkpoint(session_id, opts) do
      pid = Application.fetch_env!(:pincer, :run_info_test_pid)
      send(pid, {:load_checkpoint, session_id, opts})

      {:ok,
       %Pincer.Storage.Checkpoint{
         id: Ecto.UUID.generate(),
         session_id: session_id,
         status: "running",
         step_count: 2,
         metadata: %{"boot_id" => "a-foreign-boot", "goal" => "Stale run"},
         inserted_at: ~U[2026-01-01 00:00:00Z],
         updated_at: ~U[2026-01-01 00:00:05Z]
       }}
    end

    def save_checkpoint(session_id, checkpoint) do
      pid = Application.fetch_env!(:pincer, :run_info_test_pid)
      send(pid, {:save_checkpoint, session_id, checkpoint})
      {:ok, checkpoint}
    end
  end

  defmodule EmptyStorageStub do
    def load_checkpoint(_session_id, _opts), do: {:error, :not_found}
    def save_checkpoint(_session_id, checkpoint), do: {:ok, checkpoint}
  end

  setup do
    Application.ensure_all_started(:pincer)
    agent = start_supervised!({Agent, fn -> :ok end})
    Application.put_env(:pincer, :sub_agent_test_agent, agent)
    Blackboard.reset()

    tmp = Path.join(System.tmp_dir!(), "pincer_subagent_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    on_exit(fn ->
      Application.delete_env(:pincer, :sub_agent_test_agent)
      Blackboard.reset()
      File.rm_rf!(tmp)
    end)

    {:ok, %{tmp: tmp}}
  end

  test "posts FINISHED to Blackboard, notifies parent progress, and stops normally on success", %{
    tmp: tmp
  } do
    LLMStub.put_mode(:ok)
    parent_session = "parent_#{System.unique_integer([:positive])}"
    sub_id = "sub_ok_#{System.unique_integer([:positive])}"
    PubSub.subscribe("session:#{parent_session}")

    {:ok, pid} =
      SubAgent.start_link(
        id: sub_id,
        goal: "Summarize workspace",
        parent_session_id: parent_session,
        scope: parent_session,
        workspace_path: Path.join(tmp, sub_id),
        llm_client: LLMStub,
        tool_registry: ToolRegistryStub,
        storage: StorageStub
      )

    ref = Process.monitor(pid)
    assert_receive {:subagent_progress, %{agent_id: ^sub_id, kind: :started}}, 1000

    assert_receive {:subagent_progress,
                    %{agent_id: ^sub_id, kind: :finished, result: "Task complete"}},
                   2000

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2000

    {messages, _} = Blackboard.fetch_new(0, scope: parent_session)

    assert Enum.any?(
             messages,
             &(&1.agent_id == sub_id and &1.content == "FINISHED: Task complete")
           )
  end

  test "posts FAILED to Blackboard and stops normally on executor error", %{tmp: tmp} do
    LLMStub.put_mode(:error)
    parent_session = "parent_err_#{System.unique_integer([:positive])}"
    sub_id = "sub_err_#{System.unique_integer([:positive])}"
    PubSub.subscribe("session:#{parent_session}")

    {:ok, pid} =
      SubAgent.start_link(
        id: sub_id,
        goal: "Fail deterministically",
        parent_session_id: parent_session,
        scope: parent_session,
        workspace_path: Path.join(tmp, sub_id),
        llm_client: LLMStub,
        tool_registry: ToolRegistryStub,
        storage: StorageStub
      )

    ref = Process.monitor(pid)

    assert_receive {:subagent_progress, %{agent_id: ^sub_id, kind: :failed, reason: ":boom"}},
                   2000

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2000

    {messages, _} = Blackboard.fetch_new(0, scope: parent_session)
    assert Enum.any?(messages, &(&1.agent_id == sub_id and &1.content == "FAILED: :boom"))
  end

  test "posts FAILED to Blackboard when supervised executor task crashes unexpectedly", %{
    tmp: tmp
  } do
    LLMStub.put_mode(:crash)
    parent_session = "parent_crash_#{System.unique_integer([:positive])}"
    sub_id = "sub_crash_#{System.unique_integer([:positive])}"
    PubSub.subscribe("session:#{parent_session}")

    Process.flag(:trap_exit, true)

    {:ok, pid} =
      SubAgent.start_link(
        id: sub_id,
        goal: "Crash worker task",
        parent_session_id: parent_session,
        scope: parent_session,
        workspace_path: Path.join(tmp, sub_id),
        llm_client: LLMStub,
        tool_registry: ToolRegistryStub,
        storage: StorageStub
      )

    ref = Process.monitor(pid)
    assert_receive {:subagent_progress, %{agent_id: ^sub_id, kind: :failed}}, 2000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2000

    {messages, _} = Blackboard.fetch_new(0, scope: parent_session)

    assert Enum.any?(
             messages,
             &(&1.agent_id == sub_id and String.starts_with?(&1.content, "FAILED:"))
           )
  end

  test "passes model_override into the injected LLM client options", %{tmp: tmp} do
    LLMStub.put_mode(:ok)
    Application.put_env(:pincer, :sub_agent_test_llm_opts_pid, self())

    on_exit(fn -> Application.delete_env(:pincer, :sub_agent_test_llm_opts_pid) end)

    id = unique_id("sub_model")
    workspace = Path.join(tmp, id)

    {:ok, pid} =
      SubAgent.start_link(
        id: id,
        goal: "Use the requested model",
        workspace_path: workspace,
        llm_client: LLMStub,
        tool_registry: ToolRegistryStub,
        storage: StorageStub,
        model_override: %{provider: "openai", model: "gpt-5", thinking_level: "high"}
      )

    ref = Process.monitor(pid)
    assert_receive {:llm_opts, opts}, 2_000
    assert opts[:provider] == "openai"
    assert opts[:model] == "gpt-5"
    assert opts[:thinking_level] == "high"

    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000
  end

  test "writes a running checkpoint on start and a finished checkpoint on success", %{
    tmp: tmp
  } do
    LLMStub.put_mode(:ok)
    test_pid = self()
    id = unique_id("sub_checkpoint_ok")
    parent_session = "parent_chk_#{System.unique_integer([:positive])}"

    checkpoint_fn = fn agent_id, checkpoint ->
      send(test_pid, {:checkpoint, agent_id, checkpoint})
      {:ok, checkpoint}
    end

    {:ok, pid} =
      SubAgent.start_link(
        id: id,
        goal: "Checkpointed goal",
        parent_session_id: parent_session,
        workspace_path: Path.join(tmp, id),
        llm_client: LLMStub,
        tool_registry: ToolRegistryStub,
        storage: StorageStub,
        checkpoint_fn: checkpoint_fn,
        model_override: %{provider: "openai", model: "gpt-5", thinking_level: "high"}
      )

    ref = Process.monitor(pid)
    assert_receive {:checkpoint, ^id, running}, 1_000
    assert running.status == "running"
    assert running.step_count == 0
    assert running.metadata.kind == "subagent"
    assert running.metadata.parent_session_id == parent_session
    assert running.metadata.goal == "Checkpointed goal"
    assert running.metadata.provider == "openai"
    assert running.metadata.model == "gpt-5"
    assert is_binary(running.metadata.boot_id)
    assert is_binary(running.metadata.started_at)

    assert_receive {:checkpoint, ^id, finished}, 2_000
    assert finished.status == "finished"
    assert finished.metadata.result == "Task complete"

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
  end

  test "writes a running checkpoint after every tenth tool use", %{tmp: tmp} do
    test_pid = self()
    id = unique_id("sub_checkpoint_periodic")
    parent_session = "parent_periodic_#{System.unique_integer([:positive])}"

    checkpoint_fn = fn agent_id, checkpoint ->
      send(test_pid, {:checkpoint, agent_id, checkpoint})
      {:ok, checkpoint}
    end

    {pid, ref} = start_held_subagent(tmp, id, parent_session, checkpoint_fn)

    assert_receive {:checkpoint, ^id, initial}, 1_000
    assert initial.status == "running"
    assert initial.step_count == 0

    send_tool_uses(pid, 1..9)
    refute_receive {:checkpoint, ^id, _}, 100

    send_tool_uses(pid, 10..10)

    assert_receive {:checkpoint, ^id, tenth}, 1_000
    assert tenth.status == "running"
    assert tenth.step_count == 10
    assert tenth.history_snapshot == :erlang.term_to_binary([])
    assert tenth.metadata.kind == "subagent"
    assert tenth.metadata.parent_session_id == parent_session
    assert is_binary(tenth.metadata.boot_id)
    assert is_binary(tenth.metadata.started_at)

    send_tool_uses(pid, 11..19)
    refute_receive {:checkpoint, ^id, _}, 100

    send_tool_uses(pid, 20..20)

    assert_receive {:checkpoint, ^id, twentieth}, 1_000
    assert twentieth.status == "running"
    assert twentieth.step_count == 20

    GenServer.stop(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
  end

  test "does not write a checkpoint for the first nine tool uses", %{tmp: tmp} do
    test_pid = self()
    id = unique_id("sub_checkpoint_silent")
    parent_session = "parent_silent_#{System.unique_integer([:positive])}"

    checkpoint_fn = fn agent_id, checkpoint ->
      send(test_pid, {:checkpoint, agent_id, checkpoint})
      {:ok, checkpoint}
    end

    {pid, ref} = start_held_subagent(tmp, id, parent_session, checkpoint_fn)

    assert_receive {:checkpoint, ^id, %{status: "running", step_count: 0}}, 1_000

    send_tool_uses(pid, 1..9)
    refute_receive {:checkpoint, ^id, _}, 200

    GenServer.stop(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
  end

  test "writes the finished checkpoint with the final step count after tool uses", %{
    tmp: tmp
  } do
    test_pid = self()
    id = unique_id("sub_checkpoint_terminal")
    parent_session = "parent_terminal_#{System.unique_integer([:positive])}"

    checkpoint_fn = fn agent_id, checkpoint ->
      send(test_pid, {:checkpoint, agent_id, checkpoint})
      {:ok, checkpoint}
    end

    {pid, ref} = start_held_subagent(tmp, id, parent_session, checkpoint_fn)

    assert_receive {:checkpoint, ^id, %{status: "running", step_count: 0}}, 1_000
    assert_receive {:llm_holding, worker}, 2_000

    send_tool_uses(pid, 1..9)
    refute_receive {:checkpoint, ^id, _}, 100
    send_tool_uses(pid, 10..10)

    assert_receive {:checkpoint, ^id, periodic}, 1_000
    assert periodic.status == "running"
    assert periodic.step_count == 10

    send(worker, :release_llm)

    assert_receive {:checkpoint, ^id, finished}, 2_000
    assert finished.status == "finished"
    assert finished.step_count == 10
    assert finished.metadata.result == "Task complete"

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
  end

  test "writes a failed checkpoint when the executor fails", %{tmp: tmp} do
    LLMStub.put_mode(:error)
    test_pid = self()
    id = unique_id("sub_checkpoint_fail")

    checkpoint_fn = fn agent_id, checkpoint ->
      send(test_pid, {:checkpoint, agent_id, checkpoint})
      {:ok, checkpoint}
    end

    {:ok, pid} =
      SubAgent.start_link(
        id: id,
        goal: "Fail with checkpoints",
        workspace_path: Path.join(tmp, id),
        llm_client: LLMStub,
        tool_registry: ToolRegistryStub,
        storage: StorageStub,
        checkpoint_fn: checkpoint_fn
      )

    ref = Process.monitor(pid)
    assert_receive {:checkpoint, ^id, %{status: "running"}}, 1_000
    assert_receive {:checkpoint, ^id, failed}, 2_000
    assert failed.status == "failed"
    assert failed.metadata.error =~ "boom"

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
  end

  test "run_info returns :not_found when no checkpoint exists" do
    prev = Application.get_env(:pincer, :storage_adapter)
    Application.put_env(:pincer, :storage_adapter, EmptyStorageStub)

    on_exit(fn -> restore_env(:storage_adapter, prev) end)

    assert {:error, :not_found} =
             SubAgent.run_info("missing-#{System.unique_integer([:positive])}")
  end

  test "run_info marks a running checkpoint from a foreign VM as interrupted and persists it" do
    prev = Application.get_env(:pincer, :storage_adapter)
    Application.put_env(:pincer, :storage_adapter, RunInfoStorageStub)
    Application.put_env(:pincer, :run_info_test_pid, self())

    on_exit(fn ->
      restore_env(:storage_adapter, prev)
      Application.delete_env(:pincer, :run_info_test_pid)
    end)

    session_id = "stale_#{System.unique_integer([:positive])}"

    assert {:ok, info} = SubAgent.run_info(session_id)
    assert info.status == "interrupted"
    assert info.metadata["boot_id"] == "a-foreign-boot"

    assert_received {:load_checkpoint, ^session_id, opts}
    assert Enum.sort(opts[:status]) == ~w(completed failed finished interrupted paused running)

    assert_received {:save_checkpoint, ^session_id, persisted}
    assert persisted.status == "interrupted"
  end

  defp start_held_subagent(tmp, id, parent_session, checkpoint_fn) do
    LLMStub.put_mode(:hold)
    Application.put_env(:pincer, :sub_agent_test_hold_pid, self())

    {:ok, pid} =
      SubAgent.start_link(
        id: id,
        goal: "Periodic checkpoint goal",
        parent_session_id: parent_session,
        workspace_path: Path.join(tmp, id),
        llm_client: LLMStub,
        tool_registry: ToolRegistryStub,
        storage: StorageStub,
        checkpoint_fn: checkpoint_fn
      )

    on_exit(fn ->
      Application.delete_env(:pincer, :sub_agent_test_hold_pid)

      if Process.alive?(pid) do
        try do
          GenServer.stop(pid, :normal, 1_000)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    {pid, Process.monitor(pid)}
  end

  defp send_tool_uses(pid, range) do
    Enum.each(range, fn step -> send(pid, {:sme_tool_use, "tool #{step}"}) end)
  end

  defp unique_id(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  defp restore_env(key, nil), do: Application.delete_env(:pincer, key)
  defp restore_env(key, value), do: Application.put_env(:pincer, key, value)
end
