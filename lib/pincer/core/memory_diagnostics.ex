defmodule Pincer.Core.MemoryDiagnostics do
  @moduledoc """
  Human-facing diagnostics for runtime and persistent memory behavior.

  This module powers CLI-oriented observability commands without coupling them
  directly to storage details or mutating runtime telemetry by default.
  """

  alias Pincer.Core.MemoryObservability
  alias Pincer.Core.MemoryRecall
  alias Pincer.Ports.Storage

  @default_limit 5

  @type report :: %{
          snapshot: map(),
          health: map(),
          inventory: map(),
          recent_learnings: [map()],
          recent_history: [map()]
        }

  @type explanation :: %{
          query: String.t(),
          eligible?: boolean(),
          user_memory: String.t(),
          prompt_block: String.t(),
          hits: [map()],
          messages: [map()],
          documents: [map()],
          semantic: [map()],
          sessions: [map()],
          notes: [String.t()]
        }

  @doc """
  Returns a combined runtime and persistent memory report.
  """
  @spec report(keyword()) :: report()
  def report(opts \\ []) do
    observability = Keyword.get(opts, :observability, MemoryObservability)
    storage = Keyword.get(opts, :storage, Storage)
    limit = Keyword.get(opts, :limit, @default_limit)

    {:ok, persistence} = storage.memory_report(limit)
    snapshot = observability.snapshot()

    %{
      snapshot: snapshot,
      health: %{
        avg_hits_per_recall: ratio(snapshot.recall.total_hits, snapshot.recall.count),
        empty_recall_rate: ratio(snapshot.recall.empty_count, snapshot.recall.count),
        search_hit_rate: ratio(snapshot.search.total_hits, snapshot.search.count)
      },
      inventory: %{
        total_memories: persistence.total_documents,
        forgotten_memories: persistence.forgotten_documents,
        by_type: persistence.by_type,
        top_memories: persistence.top_documents,
        top_sessions: persistence.top_sessions
      },
      recent_learnings: storage.list_recent_learnings(limit),
      recent_history: storage.query_history()
    }
  end

  @doc """
  Explains how the runtime recall pipeline would behave for a query.
  """
  @spec explain(String.t(), keyword()) :: explanation()
  def explain(query, opts \\ []) when is_binary(query) do
    normalized_query = String.trim(query)

    if normalized_query == "" do
      raise ArgumentError, "query cannot be empty"
    else
      storage = Keyword.get(opts, :storage, Storage)
      memory_recall = Keyword.get(opts, :memory_recall, MemoryRecall)
      limit = Keyword.get(opts, :limit, @default_limit)

      recall_opts =
        opts
        |> Keyword.take([
          :workspace_path,
          :session_id,
          :embedding_fun,
          :storage,
          :memory_type,
          :include_forgotten
        ])
        |> Keyword.put(:storage, storage)
        |> Keyword.put(:limit, limit)
        |> Keyword.put(:emit_telemetry?, false)

      recall =
        memory_recall.explain([%{role: "user", content: normalized_query}], recall_opts)

      {:ok, related_sessions} = storage.search_sessions(normalized_query, limit)

      %{
        query: normalized_query,
        eligible?: recall.recall?,
        user_memory: recall.user_memory,
        prompt_block: recall.prompt_block,
        hits: recall.hits,
        messages: recall.source_hits.messages,
        documents: recall.source_hits.documents,
        semantic: recall.source_hits.semantic,
        sessions: filter_sessions(related_sessions, opts),
        notes: explain_notes(recall)
      }
    end
  end

  defp filter_sessions(sessions, opts) do
    case Keyword.get(opts, :session_id) do
      nil -> sessions
      session_id -> Enum.filter(sessions, &(&1.session_id == session_id))
    end
  end

  defp explain_notes(recall) do
    []
    |> maybe_prepend("Query is not eligible for runtime recall.", not recall.recall?)
    |> maybe_prepend("Semantic search skipped.", recall.source_outcomes.semantic == :skipped)
    |> Enum.reverse()
  end

  defp maybe_prepend(list, _note, false), do: list
  defp maybe_prepend(list, note, true), do: [note | list]

  defp ratio(_numerator, 0), do: 0.0
  defp ratio(numerator, denominator), do: numerator / denominator
end
