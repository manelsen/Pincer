defmodule Pincer.Core.Skills.ClosedLoopTest do
  use ExUnit.Case, async: false

  alias Pincer.Core.AgentPaths
  alias Pincer.Core.Introspection.Kernel
  alias Pincer.Core.Introspection.LessonStore
  alias Pincer.Core.Session.Server
  alias Pincer.Core.Skills.Generator

  defmodule MinimalStorageStub do
    @behaviour Pincer.Ports.Storage

    @impl true
    def get_messages(_session_id), do: []
    @impl true
    def save_message(_session_id, _role, _content), do: {:ok, :saved}
    @impl true
    def delete_messages(_session_id), do: :ok
    @impl true
    def ingest_bug_fix(_b, _f, _p), do: :ok
    @impl true
    def query_history, do: []
    @impl true
    def save_learning(_c, _s), do: {:ok, :saved}
    @impl true
    def save_tool_error(_t, _a, _e), do: {:ok, :saved}
    @impl true
    def list_recent_learnings(_l), do: []
    @impl true
    def get_document_metadata(_p, _w), do: nil
    @impl true
    def index_document(_p, _c, _v, _m), do: :ok
    @impl true
    def index_memory(_p, _c, _t, _v, _o), do: :ok
    @impl true
    def memory_report(_l), do: {:ok, %{}}
    @impl true
    def search_messages(_q, _l), do: {:ok, []}
    @impl true
    def search_documents(_q, _l), do: {:ok, []}
    @impl true
    def search_documents(_q, _l, _o), do: {:ok, []}
    @impl true
    def search_sessions(_q, _l), do: {:ok, []}
    @impl true
    def forget_memory(_s), do: :ok
    @impl true
    def search_similar(_t, _v, _l), do: {:ok, []}
    @impl true
    def search_graph_history(_q, _l), do: {:ok, []}
    @impl true
    def save_checkpoint(_s, _c), do: :ok
    @impl true
    def load_checkpoint(_s, _o), do: {:ok, nil}
    @impl true
    def ingest_decision(_t, _r, _f \\ nil), do: :ok
    @impl true
    def ingest_pattern(_n, _d), do: :ok
    @impl true
    def ingest_person(_n, _a \\ %{}), do: :ok
    @impl true
    def ingest_animal(_n, _s \\ nil, _o \\ nil), do: :ok
    @impl true
    def ingest_entity_relation(_fn, _ft, _r, _tn, _tt), do: :ok
    @impl true
    def upsert_pairing_state(_c, _s, _a, _r \\ %{}), do: :ok
    @impl true
    def get_pairing_state(_c, _s), do: nil
    @impl true
    def delete_pairing_state(_c, _s), do: :ok
    @impl true
    def list_pairing_states_by_channel(_c), do: []
  end

  setup do
    Pincer.Infra.Repo.delete_all(Pincer.Core.Introspection.Schema)
    Pincer.Infra.Repo.delete_all(Pincer.Core.Introspection.LessonSchema)

    existing_kernels =
      DynamicSupervisor.which_children(Kernel.Supervisor)
      |> Enum.map(&elem(&1, 1))
      |> MapSet.new()

    original_storage = Application.get_env(:pincer, :storage_adapter)
    Application.put_env(:pincer, :storage_adapter, MinimalStorageStub)

    on_exit(fn ->
      DynamicSupervisor.which_children(Kernel.Supervisor)
      |> Enum.each(fn {_id, pid, _type, _mods} ->
        if is_pid(pid) and not MapSet.member?(existing_kernels, pid) do
          DynamicSupervisor.terminate_child(Kernel.Supervisor, pid)
        end
      end)

      if original_storage do
        Application.put_env(:pincer, :storage_adapter, original_storage)
      else
        Application.delete_env(:pincer, :storage_adapter)
      end
    end)

    workspace =
      Path.join(System.tmp_dir!(), "pincer_closed_loop_#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)

    {:ok, workspace: workspace}
  end

  test "Session.Server injects discovered workspace skills and hot-refreshes on {:kernel_skills_updated, skill}",
       %{workspace: workspace} do
    session_id = "closed_loop_#{System.unique_integer([:positive])}"
    AgentPaths.ensure_workspace!(workspace, bootstrap?: false)
    skills_dir = AgentPaths.skills_dir(workspace)
    initial_skill_dir = Path.join(skills_dir, "initial-deploy-check")
    File.mkdir_p!(initial_skill_dir)

    File.write!(Path.join(initial_skill_dir, "SKILL.md"), """
    ---
    name: initial-deploy-check
    version: "0.1.0"
    description: Verify release readiness before shipping
    ---
    # Initial Deploy Check
    """)

    pid =
      start_supervised!(
        {Server,
         [
           session_id: session_id,
           root_agent_id: session_id,
           workspace_path: workspace,
           bootstrap?: false
         ]}
      )

    {:ok, status_before} = Server.get_status(session_id)
    [%{"role" => "system", "content" => prompt_before} | _] = status_before.history
    assert prompt_before =~ "LEARNED & AVAILABLE SKILLS"
    assert prompt_before =~ "initial-deploy-check"

    # Now create a high-confidence lesson, promote it deterministically, and notify Session.Server
    {:ok, _lesson} =
      LessonStore.create(session_id, %{
        content: "Check PostgreSQL connectivity and migrations before booting services.",
        confidence: 0.92,
        success_count: 3
      })

    assert {:ok, promoted} =
             Generator.promote(session_id,
               workspace_path: workspace,
               synthesize_mode: :deterministic
             )

    send(pid, {:kernel_skills_updated, promoted})
    # Ensure handle_info has been processed
    {:ok, status_after} = Server.get_status(session_id)
    [%{"role" => "system", "content" => prompt_after} | _] = status_after.history

    assert prompt_after =~ promoted.name
    assert prompt_after =~ "initial-deploy-check"
  end
end
