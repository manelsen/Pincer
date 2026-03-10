defmodule Pincer.Storage.PostgresMemoryP2Test do
  use ExUnit.Case, async: false

  alias Pincer.Infra.Repo
  alias Pincer.Storage.Adapters.Postgres

  setup do
    Application.ensure_all_started(:pincer)
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    {:ok, _} = Ecto.Adapters.SQL.query(Repo, "DELETE FROM edges", [])
    {:ok, _} = Ecto.Adapters.SQL.query(Repo, "DELETE FROM nodes", [])
    {:ok, _} = Ecto.Adapters.SQL.query(Repo, "DELETE FROM messages", [])

    :ok
  end

  test "search_documents/3 ranks typed memory by importance and returns rich citations" do
    low_path = "session://s-low/snippet/1"
    high_path = "session://s-high/snippet/1"
    vector = [1.0, 0.0]

    assert :ok =
             Postgres.index_memory(
               low_path,
               "Deploy timeout after webhook retries.",
               "technical_fact",
               vector,
               importance: 2,
               session_id: "s-low",
               line_start: 20,
               line_end: 22
             )

    assert :ok =
             Postgres.index_memory(
               high_path,
               "Deploy timeout after webhook retries.",
               "architecture_decision",
               vector,
               importance: 9,
               session_id: "s-high",
               line_start: 3,
               line_end: 4
             )

    assert {:ok, [first, second | _]} = Postgres.search_documents("deploy timeout webhook", 5)

    assert first.source == high_path
    assert first.memory_type == "architecture_decision"
    assert first.importance == 9
    assert first.citation == "#{high_path}#L3-L4"
    assert first.access_count == 1

    assert second.source == low_path
    assert second.memory_type == "technical_fact"

    assert {:ok, [filtered]} =
             Postgres.search_documents("deploy timeout webhook", 5, memory_type: "technical_fact")

    assert filtered.source == low_path
  end

  test "forget_memory/1 hides semantic memory by default but keeps retrievability" do
    path = "session://forget/snippet/1"

    assert :ok =
             Postgres.index_memory(
               path,
               "Webhook retries were fixed by raising timeout to 60 seconds.",
               "bug_solution",
               [0.0, 1.0],
               importance: 8,
               session_id: "forget-session"
             )

    assert :ok = Postgres.forget_memory(path)

    assert {:ok, results} = Postgres.search_documents("webhook retries timeout", 5)
    refute Enum.any?(results, &(&1.source == path))

    assert {:ok, [forgotten]} =
             Postgres.search_documents("webhook retries timeout", 5, include_forgotten: true)

    assert forgotten.source == path
    assert forgotten.forgotten?
  end

  test "search_sessions/2 returns explicit cross-session hits" do
    assert {:ok, _} =
             Postgres.save_message(
               "session-a",
               "assistant",
               "Deploy timeout fixed by 60s webhook timeout."
             )

    assert {:ok, _} =
             Postgres.save_message(
               "session-b",
               "user",
               "Deploy timeout happened again after webhook retries."
             )

    assert {:ok, sessions} = Postgres.search_sessions("deploy timeout webhook", 5)

    assert Enum.any?(sessions, fn session ->
             session.session_id == "session-a" and session.hit_count == 1 and
               Enum.any?(session.hits, &String.contains?(&1.citation, "session session-a"))
           end)

    assert Enum.any?(sessions, fn session ->
             session.session_id == "session-b" and session.hit_count == 1 and
               String.contains?(session.preview, "webhook retries")
           end)
  end
end
