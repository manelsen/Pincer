defmodule Pincer.Core.MemoryPipelineTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.MemoryPipeline

  defmodule StorageStub do
    def search_messages(_query, _limit),
      do: {:ok, [%{kind: :message, content: "deploy timeout fix", source: "s:1"}]}

    def search_documents(_query, _limit, _opts),
      do: {:ok, [%{kind: :document, content: "runbook", source: "d:1"}]}

    def search_documents(query, limit), do: search_documents(query, limit, [])

    def search_similar(_type, _vector, _limit),
      do: {:ok, [%{kind: :document, content: "semantic hint", source: "v:1"}]}

    def search_graph_history(_query, _limit),
      do: {:ok, [%{kind: :graph, content: "incident graph", source: "g:1"}]}
  end

  test "capture/classify/store/recall/compact/explain pipeline returns lifecycle output" do
    input = %{
      session_id: "s-100",
      project_id: "p-100",
      content: "User prefers concise answers and asked about deploy timeout.",
      query: "what do we remember about deploy timeout?"
    }

    assert {:ok, result} =
             MemoryPipeline.run(input,
               storage: StorageStub,
               embedding_fun: fn _ -> {:ok, [0.1, 0.2]} end,
               budget: %{session: 3, project: 5}
             )

    assert result.capture.session_id == "s-100"
    assert result.classify.memory_type in ["user_preference", "technical_fact", "session_summary"]
    assert result.store.status in [:stored, :skipped_budget]
    assert is_number(result.classify.confidence)
    assert is_number(result.classify.relevance)
    assert is_list(result.recall.hits)
    assert result.explain.recall_reason in [:query_eligible, :query_ineligible]
    assert result.compact.status in [:noop, :compacted]
  end

  test "enforces session/project memory budget" do
    input = %{session_id: "s-budget", project_id: "p-budget", content: "A", query: "memory"}

    assert {:ok, first} =
             MemoryPipeline.run(input,
               storage: StorageStub,
               embedding_fun: fn _ -> {:ok, [0.1]} end,
               budget: %{session: 1, project: 1}
             )

    assert first.store.status == :stored

    assert {:ok, second} =
             MemoryPipeline.run(%{input | content: "B"},
               storage: StorageStub,
               embedding_fun: fn _ -> {:ok, [0.1]} end,
               budget: %{session: 1, project: 1}
             )

    assert second.store.status == :skipped_budget
    assert second.store.reason == :session_budget_exceeded
  end

  test "compact window is based on monotonic milliseconds" do
    input = %{session_id: "s-window", project_id: "p-window", content: "A", query: "memory"}

    assert {:ok, first} =
             MemoryPipeline.run(input,
               storage: StorageStub,
               embedding_fun: fn _ -> {:ok, [0.1]} end,
               budget: %{session: 10, project: 10}
             )

    assert first.compact.status == :compacted

    assert {:ok, second} =
             MemoryPipeline.run(%{input | content: "B"},
               storage: StorageStub,
               embedding_fun: fn _ -> {:ok, [0.1]} end,
               budget: %{session: 10, project: 10}
             )

    assert second.compact.status == :noop
    assert second.compact.reason == :recently_compacted
  end
end
