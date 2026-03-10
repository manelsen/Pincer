defmodule Pincer.Core.MemoryDiagnosticsTest do
  use ExUnit.Case, async: false

  alias Pincer.Core.AgentPaths
  alias Pincer.Core.MemoryDiagnostics
  alias Pincer.Core.MemoryObservability
  alias Pincer.Core.Telemetry
  alias Pincer.Infra.Repo
  alias Pincer.Storage.Adapters.Postgres

  setup do
    Application.ensure_all_started(:pincer)
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok = MemoryObservability.reset()

    {:ok, _} = Ecto.Adapters.SQL.query(Repo, "DELETE FROM edges", [])
    {:ok, _} = Ecto.Adapters.SQL.query(Repo, "DELETE FROM nodes", [])
    {:ok, _} = Ecto.Adapters.SQL.query(Repo, "DELETE FROM messages", [])

    tmp =
      Path.join(
        System.tmp_dir!(),
        "pincer_memory_diagnostics_#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(tmp, "workspaces/explain")
    AgentPaths.ensure_workspace!(workspace, bootstrap?: false)

    File.write!(
      AgentPaths.user_path(workspace),
      """
      # User

      ## Learned User Memory
      - Prefers concise postmortems.
      """
    )

    on_exit(fn ->
      File.rm_rf!(tmp)
    end)

    {:ok, %{workspace: workspace}}
  end

  test "report/1 combines runtime snapshot with persisted memory inventory" do
    assert :ok =
             Postgres.index_memory(
               "session://ops/snippet/1",
               "Webhook timeout must stay at 60 seconds after deploys.",
               "architecture_decision",
               [1.0, 0.0],
               importance: 9,
               access_count: 7,
               session_id: "ops"
             )

    assert :ok =
             Postgres.index_memory(
               "session://ops/snippet/2",
               "Old workaround for webhook timeout drift.",
               "technical_fact",
               [1.0, 0.0],
               importance: 3,
               access_count: 1,
               session_id: "ops"
             )

    Telemetry.emit_memory_search(%{duration_ms: 10, hit_count: 3}, %{
      source: :messages,
      outcome: :ok
    })

    Telemetry.emit_memory_recall(%{duration_ms: 22, total_hits: 2, prompt_chars: 180}, %{
      eligible: true
    })

    report = MemoryDiagnostics.report(limit: 2)

    assert report.snapshot.search.count == 1
    assert report.snapshot.search.total_hits == 3
    assert report.snapshot.recall.count == 1
    assert report.health.avg_hits_per_recall == 2.0
    assert report.health.empty_recall_rate == 0.0
    assert report.health.search_hit_rate == 3.0
    assert report.inventory.total_memories == 2
    assert report.inventory.forgotten_memories == 0
    assert report.inventory.by_type["architecture_decision"] == 1
    assert report.inventory.by_type["technical_fact"] == 1
    assert hd(report.inventory.top_memories).source == "session://ops/snippet/1"
    assert report.inventory.top_sessions == [%{session_id: "ops", document_count: 2}]
  end

  test "explain/2 returns recall diagnostics and related sessions", %{workspace: workspace} do
    assert {:ok, _} =
             Postgres.save_message(
               "session-a",
               "assistant",
               "Deploy timeout was fixed after webhook retries were limited."
             )

    assert :ok =
             Postgres.index_memory(
               "session://explain/snippet/1",
               "Deploy timeout runbook says to inspect webhook retries first.",
               "technical_fact",
               [1.0, 0.0],
               importance: 8,
               session_id: "session-a"
             )

    explanation =
      MemoryDiagnostics.explain("deploy timeout webhook",
        workspace_path: workspace,
        storage: Postgres,
        limit: 5,
        embedding_fun: fn _query -> {:error, :disabled} end
      )

    assert explanation.query == "deploy timeout webhook"
    assert explanation.eligible?
    assert explanation.user_memory =~ "Prefers concise postmortems."
    assert length(explanation.messages) == 1
    assert length(explanation.documents) == 1
    assert explanation.semantic == []
    assert Enum.any?(explanation.hits, &(&1.source == "session://explain/snippet/1"))
    assert Enum.any?(explanation.sessions, &(&1.session_id == "session-a"))
    assert Enum.any?(explanation.notes, &String.contains?(&1, "Semantic search skipped"))
  end
end
