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
    def stream_completion(_messages, _opts) do
      case mode() do
        :ok -> {:ok, [%{"choices" => [%{"delta" => %{"content" => "Task complete"}}]}], nil}
        :error -> {:error, :boom}
        :crash -> raise "kaboom"
      end
    end

    @impl true
    def chat_completion(_messages, _opts) do
      case mode() do
        :ok -> {:ok, %{"role" => "assistant", "content" => "Task complete"}, nil}
        :error -> {:error, :boom}
        :crash -> raise "kaboom"
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
end
