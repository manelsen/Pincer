defmodule Pincer.Core.Session.ServerTest do
  use ExUnit.Case, async: false

  alias Pincer.Core.AgentPaths
  alias Pincer.Core.Orchestration.Blackboard
  alias Pincer.Core.Session.Server

  defmodule StorageStub do
    @behaviour Pincer.Ports.Storage

    def put_messages(session_id, messages) do
      Agent.update(agent(), &Map.put(&1, {:messages, session_id}, messages))
    end

    def saved_messages(session_id) do
      Agent.get(agent(), &Map.get(&1, {:saved, session_id}, []))
    end

    @impl true
    def get_messages(session_id) do
      Agent.get(agent(), &Map.get(&1, {:messages, session_id}, []))
    end

    @impl true
    def save_message(session_id, role, content) do
      Agent.update(agent(), fn state ->
        Map.update(state, {:saved, session_id}, [%{role: role, content: content}], fn entries ->
          entries ++ [%{role: role, content: content}]
        end)
      end)

      {:ok, %{session_id: session_id, role: role, content: content}}
    end

    @impl true
    def delete_messages(session_id) do
      Agent.update(agent(), &Map.delete(&1, {:messages, session_id}))
      :ok
    end

    @impl true
    def ingest_bug_fix(_bug_desc, _fix_summary, _file_path), do: :ok

    @impl true
    def query_history, do: []

    @impl true
    def save_learning(_category, _summary), do: {:ok, :saved}

    @impl true
    def save_tool_error(_tool, _args, _error), do: {:ok, :saved}

    @impl true
    def list_recent_learnings(_limit), do: []

    @impl true
    def index_document(_path, _content, _vector), do: :ok

    @impl true
    def search_similar(_type, _vector, _limit), do: {:ok, []}

    defp agent do
      Application.fetch_env!(:pincer, :session_server_test_agent)
    end
  end

  setup do
    agent = start_supervised!({Agent, fn -> %{} end})

    original_storage = Application.get_env(:pincer, :storage_adapter)
    Application.put_env(:pincer, :storage_adapter, StorageStub)
    Application.put_env(:pincer, :session_server_test_agent, agent)
    Blackboard.reset()

    on_exit(fn ->
      Application.put_env(:pincer, :storage_adapter, original_storage)
      Application.delete_env(:pincer, :session_server_test_agent)
      Blackboard.reset()
    end)

    :ok
  end

  test "bootstrap is inactive when identity and soul already exist" do
    root = Path.join(System.tmp_dir!(), "pincer_bootstrap_#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspaces/bootstrap_session")
    File.mkdir_p!(AgentPaths.pincer_dir(workspace))

    identity_path = AgentPaths.identity_path(workspace)
    soul_path = AgentPaths.soul_path(workspace)
    bootstrap_path = AgentPaths.bootstrap_path(workspace)

    File.write!(identity_path, "# identity")
    File.write!(soul_path, "# soul")
    File.write!(bootstrap_path, "# bootstrap")

    refute Server.bootstrap_active?(workspace, bootstrap_path: bootstrap_path)
  end

  test "system prompt reads workspace-local .pincer files instead of legacy root files" do
    tmp = Path.join(System.tmp_dir!(), "pincer_prompt_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    cwd = File.cwd!()
    session_id = "session_server_prompt_#{System.unique_integer([:positive])}"
    workspace = Path.join(tmp, "workspaces/#{session_id}")

    File.cd!(tmp)

    on_exit(fn ->
      File.cd!(cwd)
      File.rm_rf!(tmp)
    end)

    File.write!("SOUL.md", "# Legacy Soul")
    File.write!("IDENTITY.md", "# Legacy Identity")
    File.write!("USER.md", "# Legacy User")

    AgentPaths.ensure_workspace!(workspace, bootstrap?: false)
    File.write!(AgentPaths.identity_path(workspace), "# Workspace Identity")
    File.write!(AgentPaths.soul_path(workspace), "# Workspace Soul")
    File.write!(AgentPaths.user_path(workspace), "# Workspace User")

    start_supervised!(
      {Server, [session_id: session_id, workspace_path: workspace, bootstrap?: false]}
    )

    assert {:ok, state} = Server.get_status(session_id)
    [system_msg | _] = state.history
    prompt = system_msg["content"]

    assert prompt =~ "# Workspace Identity"
    assert prompt =~ "# Workspace Soul"
    assert prompt =~ "# Workspace User"
    refute prompt =~ "# Legacy Soul"
  end

  test "persists assistant replies for recovery" do
    session_id = "session_server_test_#{System.unique_integer([:positive])}"
    StorageStub.put_messages(session_id, [%{"role" => "user", "content" => "existing"}])

    pid = start_supervised!({Server, [session_id: session_id]})

    send(pid, {:assistant_reply_finished, "hello"})

    send(
      pid,
      {:executor_finished, [%{"role" => "assistant", "content" => "final"}], "final", %{}}
    )

    Process.sleep(50)

    assert StorageStub.saved_messages(session_id) == [
             %{role: "assistant", content: "hello"},
             %{role: "assistant", content: "final"}
           ]
  end

  test "recovery only ingests blackboard updates from the same scope" do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "pincer_blackboard_scope_#{System.unique_integer([:positive])}"
      )

    session_id = "telegram_#{System.unique_integer([:positive])}"
    root_agent_id = "a1b2c3"
    workspace = Path.join(tmp, "workspaces/#{root_agent_id}")

    File.mkdir_p!(tmp)

    on_exit(fn ->
      File.rm_rf!(tmp)
    end)

    AgentPaths.ensure_workspace!(workspace, bootstrap?: false)

    _ = Blackboard.post("system", "Annie private update", nil, scope: root_agent_id)
    _ = Blackboard.post("system", "Lucie private update", nil, scope: "lucie")

    start_supervised!(
      {Server, [session_id: session_id, root_agent_id: root_agent_id, workspace_path: workspace]}
    )

    Process.sleep(80)

    assert {:ok, state} = Server.get_status(session_id)
    combined = Enum.map_join(state.history, "\n", &Map.get(&1, "content", ""))

    assert combined =~ "Annie private update"
    refute combined =~ "Lucie private update"
  end

  test "session server loads workspace from root_agent_id instead of session_id" do
    tmp = Path.join(System.tmp_dir!(), "pincer_root_agent_#{System.unique_integer([:positive])}")
    session_id = "telegram_123"
    root_agent_id = "a1b2c3"
    workspace = Path.join(tmp, "workspaces/#{root_agent_id}")

    File.mkdir_p!(tmp)

    on_exit(fn ->
      File.rm_rf!(tmp)
    end)

    AgentPaths.ensure_workspace!(workspace, bootstrap?: false)
    File.write!(AgentPaths.identity_path(workspace), "# Annie\n")
    File.write!(AgentPaths.soul_path(workspace), "# Annie Soul\n")

    start_supervised!(
      {Server, [session_id: session_id, root_agent_id: root_agent_id, workspace_path: workspace]}
    )

    assert {:ok, state} = Server.get_status(session_id)
    assert state.workspace_path == workspace
    assert state.blackboard_scope == root_agent_id
    assert hd(state.history)["content"] =~ "# Annie"
  end

  test "system prompt keeps mapped agent personas isolated across workspaces" do
    tmp =
      Path.join(System.tmp_dir!(), "pincer_persona_scope_#{System.unique_integer([:positive])}")

    annie_id = "annie_#{System.unique_integer([:positive])}"
    lucie_id = "lucie_#{System.unique_integer([:positive])}"
    annie_workspace = Path.join(tmp, "workspaces/#{annie_id}")
    lucie_workspace = Path.join(tmp, "workspaces/#{lucie_id}")

    File.mkdir_p!(tmp)

    on_exit(fn ->
      File.rm_rf!(tmp)
    end)

    AgentPaths.ensure_workspace!(annie_workspace, bootstrap?: false)
    AgentPaths.ensure_workspace!(lucie_workspace, bootstrap?: false)

    File.write!(AgentPaths.identity_path(annie_workspace), "# Annie\nSecretaria sutil\n")
    File.write!(AgentPaths.soul_path(annie_workspace), "# Annie Soul\n")
    File.write!(AgentPaths.identity_path(lucie_workspace), "# Lucie\nAssistente sarcastica\n")
    File.write!(AgentPaths.soul_path(lucie_workspace), "# Lucie Soul\n")

    start_supervised!(%{
      id: annie_id,
      start:
        {Server, :start_link,
         [[session_id: annie_id, workspace_path: annie_workspace, bootstrap?: false]]}
    })

    start_supervised!(%{
      id: lucie_id,
      start:
        {Server, :start_link,
         [[session_id: lucie_id, workspace_path: lucie_workspace, bootstrap?: false]]}
    })

    assert {:ok, annie_state} = Server.get_status(annie_id)
    assert {:ok, lucie_state} = Server.get_status(lucie_id)

    annie_prompt = annie_state.history |> hd() |> Map.fetch!("content")
    lucie_prompt = lucie_state.history |> hd() |> Map.fetch!("content")

    assert annie_prompt =~ "# Annie"
    assert annie_prompt =~ "Secretaria sutil"
    refute annie_prompt =~ "# Lucie"

    assert lucie_prompt =~ "# Lucie"
    assert lucie_prompt =~ "Assistente sarcastica"
    refute lucie_prompt =~ "# Annie"
  end
end
