defmodule Pincer.Core.Session.ServerTest do
  use ExUnit.Case, async: false

  alias Pincer.Core.AgentPaths
  alias Pincer.Core.Orchestration.Blackboard
  alias Pincer.Core.Session.Server
  alias PincerPorts.Structs.Usage

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
    def get_document_metadata(_path, _workspace_root), do: nil

    @impl true
    def index_document(_path, _content, _vector, _metadata), do: :ok

    @impl true
    def index_memory(_path, _content, _memory_type, _vector, _opts), do: :ok

    @impl true
    def memory_report(_limit), do: {:ok, %{}}

    @impl true
    def search_messages(_query, _limit), do: {:ok, []}

    @impl true
    def search_documents(_query, _limit), do: {:ok, []}

    @impl true
    def search_documents(_query, _limit, _opts), do: {:ok, []}

    @impl true
    def search_sessions(_query, _limit), do: {:ok, []}

    @impl true
    def forget_memory(_source), do: :ok

    @impl true
    def search_similar(_type, _vector, _limit), do: {:ok, []}

    @impl true
    def search_graph_history(_query, _limit), do: {:ok, []}
    @impl true
    def save_checkpoint(_session_id, _checkpoint), do: :ok
    @impl true
    def load_checkpoint(_session_id, _opts), do: {:ok, nil}

    @impl true
    def ingest_decision(_topic, _rationale, _file \\ nil), do: :ok

    @impl true
    def ingest_pattern(_name, _description), do: :ok

    @impl true
    def ingest_person(_name, _attrs \\ %{}), do: :ok

    @impl true
    def ingest_animal(_name, _species \\ nil, _notes \\ nil), do: :ok

    @impl true
    def ingest_entity_relation(_from_name, _from_type, _relation, _to_name, _to_type),
      do: :ok

    @impl true
    def upsert_pairing_state(_session_id, _channel, _state, _opts \\ []), do: :ok

    @impl true
    def get_pairing_state(_session_id, _channel), do: {:ok, nil}

    @impl true
    def delete_pairing_state(_session_id, _channel), do: :ok

    @impl true
    def list_pairing_states_by_channel(_channel), do: {:ok, []}

    @impl true
    def purge_invalid_documents(_prefixes), do: {:ok, 0}

    defp agent do
      Application.fetch_env!(:pincer, :session_server_test_agent)
    end
  end

  defmodule ReflectionLLMStub do
    @behaviour Pincer.Ports.LLM

    @impl true
    def stream_completion(_messages, _opts) do
      {:ok, [%{"choices" => [%{"delta" => %{"content" => "reflexão ok"}}]}]}
    end

    @impl true
    def chat_completion(_messages, _opts) do
      {:ok, %{"role" => "assistant", "content" => "reflexão ok"}, nil}
    end

    @impl true
    def list_providers, do: []
    @impl true
    def list_models(_provider_id), do: []
    @impl true
    def transcribe_audio(_file_path, _opts), do: {:error, :not_implemented}
    @impl true
    def generate_embedding(_text, _opts), do: {:error, :not_implemented}
    @impl true
    def provider_config(_provider_id), do: nil
  end

  defmodule LLMStub do
    @behaviour Pincer.Ports.LLM

    def put_handlers(handlers) when is_map(handlers) do
      agent = Application.fetch_env!(:pincer, :session_server_test_agent)
      Agent.update(agent, &Map.put(&1, :llm_handlers, handlers))
    end

    defp handler(key) do
      case Application.get_env(:pincer, :session_server_test_agent) do
        nil -> nil
        agent -> Agent.get(agent, fn state -> get_in(state, [:llm_handlers, key]) end)
      end
    end

    @impl true
    def stream_completion(messages, opts) do
      case handler(:stream) do
        fun when is_function(fun, 2) -> fun.(messages, opts)
        other -> other || {:ok, [%{"choices" => [%{"delta" => %{"content" => "ok"}}]}], nil}
      end
    end

    @impl true
    def chat_completion(messages, opts) do
      case handler(:chat) do
        fun when is_function(fun, 2) -> fun.(messages, opts)
        other -> other || {:ok, %{"role" => "assistant", "content" => "ok"}, nil}
      end
    end

    @impl true
    def list_providers, do: []
    @impl true
    def list_models(_provider_id), do: []
    @impl true
    def transcribe_audio(_file_path, _opts), do: {:error, :not_implemented}
    @impl true
    def generate_embedding(_text, _opts), do: {:error, :not_implemented}
    @impl true
    def provider_config(_provider_id), do: nil
  end

  setup do
    agent = start_supervised!({Agent, fn -> %{} end})

    existing_kernels =
      snapshot_kernel_pids()

    original_storage = Application.get_env(:pincer, :storage_adapter)
    Application.put_env(:pincer, :storage_adapter, StorageStub)
    Application.put_env(:pincer, :session_server_test_agent, agent)
    Blackboard.reset()

    on_exit(fn ->
      terminate_new_kernels(existing_kernels)
      Application.put_env(:pincer, :storage_adapter, original_storage)
      Application.delete_env(:pincer, :session_server_test_agent)
      Blackboard.reset()
    end)

    :ok
  end

  defp snapshot_kernel_pids do
    case Process.whereis(Pincer.Core.Introspection.Kernel.Supervisor) do
      nil ->
        MapSet.new()

      _pid ->
        Pincer.Core.Introspection.Kernel.Supervisor
        |> DynamicSupervisor.which_children()
        |> Enum.map(fn {_, pid, _, _} -> pid end)
        |> MapSet.new()
    end
  end

  defp terminate_new_kernels(existing_kernels) do
    case Process.whereis(Pincer.Core.Introspection.Kernel.Supervisor) do
      nil ->
        :ok

      _pid ->
        Pincer.Core.Introspection.Kernel.Supervisor
        |> DynamicSupervisor.which_children()
        |> Enum.each(fn {_, pid, _, _} ->
          if is_pid(pid) and not MapSet.member?(existing_kernels, pid) do
            DynamicSupervisor.terminate_child(Pincer.Core.Introspection.Kernel.Supervisor, pid)
          end
        end)
    end
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
    session_id = "session_server_prompt_#{System.unique_integer([:positive])}"
    workspace = Path.join(tmp, "workspaces/#{session_id}")

    on_exit(fn -> File.rm_rf!(tmp) end)

    File.write!(Path.join(tmp, "SOUL.md"), "# Legacy Soul")
    File.write!(Path.join(tmp, "IDENTITY.md"), "# Legacy Identity")
    File.write!(Path.join(tmp, "USER.md"), "# Legacy User")

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

  test "workspace bootstrap uses template workspace as source of truth" do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "pincer_template_bootstrap_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    workspace = Path.join(tmp, "workspaces/template_agent")

    on_exit(fn -> File.rm_rf!(tmp) end)

    template_dir = Path.join(tmp, "workspaces/.template/.pincer")
    File.mkdir_p!(template_dir)
    File.write!(Path.join(template_dir, "IDENTITY.md"), "# Template Identity\n")
    File.write!(Path.join(template_dir, "SOUL.md"), "# Template Soul\n")
    File.write!(Path.join(template_dir, "USER.md"), "# Template User\n")
    File.write!(Path.join(template_dir, "BOOTSTRAP.md"), "# Template Bootstrap\n")

    AgentPaths.ensure_workspace!(workspace, template_root: Path.join(tmp, "workspaces"))

    # IDENTITY and SOUL are NOT seeded — deferred to bootstrap ritual
    refute File.exists?(AgentPaths.identity_path(workspace))
    refute File.exists?(AgentPaths.soul_path(workspace))
    assert File.read!(AgentPaths.user_path(workspace)) == "# Template User\n"
    assert File.read!(AgentPaths.bootstrap_path(workspace)) == "# Template Bootstrap\n"
  end

  test "bootstrap is active when identity and soul are absent" do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "pincer_bootstrap_absent_#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(tmp, "workspaces/bootstrap_absent")
    File.mkdir_p!(AgentPaths.pincer_dir(workspace))
    File.write!(AgentPaths.bootstrap_path(workspace), "# Bootstrap\n")

    assert Server.bootstrap_active?(workspace)
  end

  test "persists assistant replies for recovery" do
    tmp = Path.join(System.tmp_dir!(), "pincer_persist_#{System.unique_integer([:positive])}")
    session_id = "session_server_test_#{System.unique_integer([:positive])}"
    workspace = Path.join(tmp, "workspaces/#{session_id}")

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    LLMStub.put_handlers(%{
      chat: {:ok, %{"role" => "assistant", "content" => "hello"}, nil},
      stream: {:ok, [%{"choices" => [%{"delta" => %{"content" => "final"}}]}], nil}
    })

    AgentPaths.ensure_workspace!(workspace, bootstrap?: false)
    StorageStub.put_messages(session_id, [%{"role" => "user", "content" => "existing"}])

    pid =
      start_supervised!(
        {Server,
         [
           session_id: session_id,
           workspace_path: workspace,
           bootstrap?: false,
           llm_client: LLMStub
         ]}
      )

    send(pid, :trigger_bootstrap)

    wait_until(1000, fn ->
      if Enum.any?(StorageStub.saved_messages(session_id), &(&1.content == "hello")), do: :ok
    end)

    send(pid, {:cron_trigger, "continue"})

    wait_until(1000, fn ->
      if Enum.any?(StorageStub.saved_messages(session_id), &(&1.content == "final")), do: :ok
    end)

    _ = :sys.get_state(pid)

    assert Enum.filter(StorageStub.saved_messages(session_id), &(&1.role == "assistant")) == [
             %{role: "assistant", content: "hello"},
             %{role: "assistant", content: "final"}
           ]
  end

  test "publishes friendly executor errors instead of raw provider payloads" do
    tmp = Path.join(System.tmp_dir!(), "pincer_error_#{System.unique_integer([:positive])}")
    session_id = "session_server_error_#{System.unique_integer([:positive])}"
    workspace = Path.join(tmp, "workspaces/#{session_id}")

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    err =
      {:error,
       {:http_error, 400,
        ~s({"error":{"message":"`tool calling` is not supported with this model"}})}}

    LLMStub.put_handlers(%{stream: err, chat: err})

    AgentPaths.ensure_workspace!(workspace, bootstrap?: false)
    Pincer.Infra.PubSub.subscribe("session:#{session_id}")

    pid =
      start_supervised!(
        {Server,
         [
           session_id: session_id,
           workspace_path: workspace,
           bootstrap?: false,
           llm_client: LLMStub
         ]}
      )

    send(pid, {:cron_trigger, "run failing turn"})

    assert_receive {:agent_response, message}, 2000
    assert message =~ "nao suporta"
    assert message =~ "ferramentas"
    refute message =~ "`tool calling`"

    {:ok, state} = Server.get_status(session_id)
    assert state.status == :idle
    assert state.worker_pid == nil
    assert state.worker_ref == nil
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

    # Blackboard ingest runs inside a spawned Task that replies via :recovery_catch_up_done.
    # Poll get_status until the scoped update lands in history (or fail fast after 500ms).
    combined =
      wait_until(500, fn ->
        {:ok, state} = Server.get_status(session_id)
        text = Enum.map_join(state.history, "\n", &Map.get(&1, "content", ""))
        if text =~ "Annie private update", do: text
      end)

    assert combined =~ "Annie private update"
    refute combined =~ "Lucie private update"
  end

  defp wait_until(timeout_ms, fun, interval_ms \\ 10) do
    Pincer.Test.Support.SyncHelpers.eventually(fun,
      timeout: timeout_ms,
      interval: interval_ms,
      message: "wait_until/2 timed out"
    )
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

  test "session delegates traces to Consciousness Kernel" do
    tmp = Path.join(System.tmp_dir!(), "pincer_kernel_#{System.unique_integer([:positive])}")
    session_id = "session_kernel_#{System.unique_integer([:positive])}"
    workspace = Path.join(tmp, "workspaces/#{session_id}")

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    AgentPaths.ensure_workspace!(workspace, bootstrap?: false)

    pid =
      start_supervised!(
        {Server, [session_id: session_id, workspace_path: workspace, bootstrap?: false]}
      )

    trace = %{"steps" => [%{"kind" => "memory"}, %{"kind" => "error"}]}
    send(pid, {:executor_trace, trace})

    # get_status drains the Server mailbox (processing the trace + forwarding to kernel).
    assert {:ok, state} = Server.get_status(session_id)
    assert state.last_executor_trace == trace

    # Verify Kernel received the trace (session_id is used as root_agent_id by default).
    # :sys.get_state on the kernel syncs with its mailbox.
    [{kernel_pid, _}] = Registry.lookup(Pincer.Core.Introspection.Kernel.Registry, session_id)
    kernel_state = :sys.get_state(kernel_pid)
    assert kernel_state.last_trace == trace
  end

  test "history is pruned when it exceeds max_history_messages" do
    tmp = Path.join(System.tmp_dir!(), "pincer_prune_#{System.unique_integer([:positive])}")
    session_id = "session_prune_#{System.unique_integer([:positive])}"
    workspace = Path.join(tmp, "workspaces/#{session_id}")

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    LLMStub.put_handlers(%{
      stream:
        {:ok, [%{"choices" => [%{"delta" => %{"content" => "ok"}}]}],
         %{"prompt_tokens" => 10, "completion_tokens" => 5}}
    })

    AgentPaths.ensure_workspace!(workspace, bootstrap?: false)

    StorageStub.put_messages(
      session_id,
      Enum.map(1..19, &%{"role" => "user", "content" => "msg #{&1}"})
    )

    Application.put_env(:pincer, :max_history_messages, 5)
    on_exit(fn -> Application.delete_env(:pincer, :max_history_messages) end)

    pid =
      start_supervised!(
        {Server,
         [
           session_id: session_id,
           workspace_path: workspace,
           bootstrap?: false,
           llm_client: LLMStub
         ]}
      )

    send(pid, {:cron_trigger, "msg 20"})

    state =
      wait_until(2000, fn ->
        {:ok, st} = Server.get_status(session_id)

        if st.status == :idle and length(Enum.reject(st.history, &(&1["role"] == "system"))) == 5,
          do: st
      end)

    non_system = Enum.reject(state.history, &(&1["role"] == "system"))
    assert length(non_system) == 5
    assert List.last(non_system)["content"] == "ok"

    assert Enum.any?(
             state.history,
             &(&1["role"] == "system" and &1["content"] =~ "earlier messages removed")
           )
  end

  test "session receives self_state updates from Kernel" do
    tmp = Path.join(System.tmp_dir!(), "pincer_kstate_#{System.unique_integer([:positive])}")
    session_id = "session_kstate_#{System.unique_integer([:positive])}"
    workspace = Path.join(tmp, "workspaces/#{session_id}")

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    AgentPaths.ensure_workspace!(workspace, bootstrap?: false)

    pid =
      start_supervised!(
        {Server, [session_id: session_id, workspace_path: workspace, bootstrap?: false]}
      )

    # Simulate a kernel broadcast
    mock_state = %{agent_id: session_id, focus: "testing"}
    send(pid, {:kernel_self_state_updated, mock_state})

    # get_status drains the mailbox — the prior send is processed before it returns.
    assert {:ok, state} = Server.get_status(session_id)
    assert state.self_state == mock_state
  end

  test "correlates executor turn via TaskSupervisor, accumulates Usage, and clears worker_ref" do
    tmp = Path.join(System.tmp_dir!(), "pincer_corr_#{System.unique_integer([:positive])}")
    session_id = "session_corr_#{System.unique_integer([:positive])}"
    workspace = Path.join(tmp, "workspaces/#{session_id}")

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    LLMStub.put_handlers(%{
      stream:
        {:ok, [%{"choices" => [%{"delta" => %{"content" => "Resposta correlacionada"}}]}],
         %{"prompt_tokens" => 12, "completion_tokens" => 8}}
    })

    AgentPaths.ensure_workspace!(workspace, bootstrap?: false)
    Pincer.Infra.PubSub.subscribe("session:#{session_id}")

    pid =
      start_supervised!(
        {Server,
         [
           session_id: session_id,
           workspace_path: workspace,
           bootstrap?: false,
           llm_client: LLMStub
         ]}
      )

    send(pid, {:cron_trigger, "hello"})

    assert_receive {:agent_response, "Resposta correlacionada",
                    %Usage{prompt_tokens: 12, completion_tokens: 8, total_tokens: 20}},
                   2000

    {:ok, state} = Server.get_status(session_id)
    assert state.status == :idle
    assert state.worker_pid == nil
    assert state.worker_ref == nil

    assert state.token_usage_total == %Usage{
             prompt_tokens: 12,
             completion_tokens: 8,
             total_tokens: 20
           }

    assert List.last(StorageStub.saved_messages(session_id)) == %{
             role: "assistant",
             content: "Resposta correlacionada"
           }
  end

  test "recovers gracefully when supervised executor task crashes" do
    tmp = Path.join(System.tmp_dir!(), "pincer_crash_#{System.unique_integer([:positive])}")
    session_id = "session_crash_#{System.unique_integer([:positive])}"
    workspace = Path.join(tmp, "workspaces/#{session_id}")

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    LLMStub.put_handlers(%{stream: fn _msgs, _opts -> raise "boom" end})

    AgentPaths.ensure_workspace!(workspace, bootstrap?: false)
    Pincer.Infra.PubSub.subscribe("session:#{session_id}")

    pid =
      start_supervised!(
        {Server,
         [
           session_id: session_id,
           workspace_path: workspace,
           bootstrap?: false,
           llm_client: LLMStub
         ]}
      )

    send(pid, {:cron_trigger, "crash me"})

    assert_receive {:agent_response, err_msg}, 2000
    assert err_msg =~ "❌"
    assert Process.alive?(pid)

    {:ok, state} = Server.get_status(session_id)
    assert state.status == :idle
    assert state.worker_pid == nil
    assert state.worker_ref == nil
  end

  test "ignores stale refs and uncorrelated legacy executor messages" do
    tmp = Path.join(System.tmp_dir!(), "pincer_stale_#{System.unique_integer([:positive])}")
    session_id = "session_stale_#{System.unique_integer([:positive])}"
    workspace = Path.join(tmp, "workspaces/#{session_id}")

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    AgentPaths.ensure_workspace!(workspace, bootstrap?: false)
    Pincer.Infra.PubSub.subscribe("session:#{session_id}")

    pid =
      start_supervised!(
        {Server, [session_id: session_id, workspace_path: workspace, bootstrap?: false]}
      )

    {:ok, initial_state} = Server.get_status(session_id)

    stale_ref = make_ref()
    send(pid, {stale_ref, {:ok, [], "stale", nil}})
    send(pid, {stale_ref, {:error, :stale}})
    send(pid, {:DOWN, stale_ref, :process, self(), :boom})
    send(pid, {:assistant_reply_finished, "legacy"})
    send(pid, {:executor_finished, [], "legacy", %{}})
    send(pid, {:executor_failed, :legacy})

    {:ok, after_state} = Server.get_status(session_id)
    assert after_state.history == initial_state.history
    assert after_state.pending_evals == %{}
    assert StorageStub.saved_messages(session_id) == []
    refute_receive {:agent_response, _}, 50
    refute_receive {:agent_response, _, _}, 50
  end

  test "supervises unsolicited evals in pending_evals for reply, ignore, and crash" do
    tmp = Path.join(System.tmp_dir!(), "pincer_evals_#{System.unique_integer([:positive])}")
    session_id = "session_evals_#{System.unique_integer([:positive])}"
    workspace = Path.join(tmp, "workspaces/#{session_id}")

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    AgentPaths.ensure_workspace!(workspace, bootstrap?: false)
    Pincer.Infra.PubSub.subscribe("session:#{session_id}")

    pid =
      start_supervised!(
        {Server,
         [
           session_id: session_id,
           workspace_path: workspace,
           bootstrap?: false,
           llm_client: LLMStub
         ]}
      )

    # 1. Meaningful unsolicited reply
    LLMStub.put_handlers(%{
      chat:
        {:ok, %{"content" => "Olá! Eu sou o Pincer."},
         %{"prompt_tokens" => 4, "completion_tokens" => 6}}
    })

    send(pid, :trigger_bootstrap)

    assert_receive {:agent_response, "Olá! Eu sou o Pincer.",
                    %Usage{prompt_tokens: 4, completion_tokens: 6, total_tokens: 10}},
                   2000

    state1 =
      wait_until(1000, fn ->
        {:ok, st} = Server.get_status(session_id)
        if st.pending_evals == %{}, do: st
      end)

    assert List.last(state1.history) == %{
             "role" => "assistant",
             "content" => "Olá! Eu sou o Pincer."
           }

    assert state1.token_usage_total == %Usage{
             prompt_tokens: 4,
             completion_tokens: 6,
             total_tokens: 10
           }

    assert StorageStub.saved_messages(session_id) == [
             %{role: "assistant", content: "Olá! Eu sou o Pincer."}
           ]

    # 2. IGNORE response
    LLMStub.put_handlers(%{chat: {:ok, %{"content" => "IGNORE"}, nil}})
    send(pid, :trigger_bootstrap)

    wait_until(1000, fn ->
      # Wait a beat after mailbox flush so async task completes
      {:ok, st} = Server.get_status(session_id)
      if st.pending_evals == %{}, do: :ok
    end)

    {:ok, state2} = Server.get_status(session_id)
    assert length(state2.history) == length(state1.history)
    refute_receive {:agent_response, _, _}, 50

    # 3. Task crash during eval
    LLMStub.put_handlers(%{chat: fn _msgs, _opts -> raise "eval crash" end})
    send(pid, :trigger_bootstrap)

    wait_until(1000, fn ->
      {:ok, st} = Server.get_status(session_id)
      if st.pending_evals == %{}, do: :ok
    end)

    assert Process.alive?(pid)
    {:ok, state3} = Server.get_status(session_id)
    assert state3.pending_evals == %{}
  end
end
