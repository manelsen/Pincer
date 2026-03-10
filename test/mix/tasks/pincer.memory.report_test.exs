defmodule Mix.Tasks.Pincer.MemoryReportTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  alias Pincer.Core.MemoryObservability
  alias Pincer.Core.Telemetry
  alias Pincer.Infra.Repo
  alias Pincer.Storage.Adapters.Postgres

  @task "pincer.memory.report"

  setup do
    Application.ensure_all_started(:pincer)
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok = MemoryObservability.reset()

    {:ok, _} = Ecto.Adapters.SQL.query(Repo, "DELETE FROM edges", [])
    {:ok, _} = Ecto.Adapters.SQL.query(Repo, "DELETE FROM nodes", [])
    {:ok, _} = Ecto.Adapters.SQL.query(Repo, "DELETE FROM messages", [])

    on_exit(fn ->
      Mix.Task.reenable(@task)
    end)

    :ok
  end

  test "prints runtime and persistent memory summary" do
    assert :ok =
             Postgres.index_memory(
               "session://report/snippet/1",
               "Deploy timeout fixed by increasing webhook timeout.",
               "technical_fact",
               [1.0, 0.0],
               importance: 9,
               access_count: 3,
               session_id: "session-report"
             )

    assert :ok =
             Postgres.index_memory(
               "session://report/snippet/2",
               "User prefers concise postmortems.",
               "user_preference",
               [0.0, 1.0],
               importance: 7,
               access_count: 1,
               session_id: "session-report"
             )

    Telemetry.emit_memory_search(%{duration_ms: 10, hit_count: 2}, %{
      source: :messages,
      outcome: :ok
    })

    Telemetry.emit_memory_recall(%{duration_ms: 14, total_hits: 2, prompt_chars: 120}, %{
      eligible: true
    })

    output =
      capture_io(fn ->
        Mix.Task.run(@task, ["--limit", "5"])
      end)

    assert output =~ "Pincer Memory Report"
    assert output =~ "Recall: count=1 eligible=1 hits=2"
    assert output =~ "Search: count=1 hits=2"
    assert output =~ "Documents: total=2 forgotten=0"
    assert output =~ "technical_fact: 1"
    assert output =~ "user_preference: 1"
    assert output =~ "session://report/snippet/1"
    assert output =~ "session-report: 2"
  end
end
