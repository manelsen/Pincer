defmodule Pincer.Core.MemoryPipeline do
  @moduledoc """
  Unified memory lifecycle pipeline:
  capture -> classify -> store -> recall -> compact -> explain.
  """

  alias Pincer.Core.Memory
  alias Pincer.Core.MemoryRecall
  alias Pincer.Core.MemoryTypes

  @table __MODULE__

  @spec run(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(input, opts \\ []) when is_map(input) and is_list(opts) do
    ensure_table()

    capture = capture(input)
    classify = classify(capture)
    store = store(capture, classify, opts)
    recall = recall(capture, opts)
    compact = compact(capture, opts)
    explain = explain(capture, recall)

    {:ok,
     %{
       capture: capture,
       classify: classify,
       store: store,
       recall: recall,
       compact: compact,
       explain: explain
     }}
  end

  defp capture(input) do
    %{
      session_id: Map.get(input, :session_id) || Map.get(input, "session_id") || "unknown",
      project_id: Map.get(input, :project_id) || Map.get(input, "project_id") || "default",
      content: Map.get(input, :content) || Map.get(input, "content") || "",
      query: Map.get(input, :query) || Map.get(input, "query")
    }
  end

  defp classify(capture) do
    content = capture.content |> to_string() |> String.downcase()
    query = (capture.query || "") |> String.downcase()
    signal = "#{content} #{query}"

    memory_type =
      cond do
        String.contains?(signal, "prefer") -> "user_preference"
        String.contains?(signal, "bug") or String.contains?(signal, "timeout") -> "technical_fact"
        true -> "session_summary"
      end

    confidence =
      cond do
        memory_type == "user_preference" -> 0.88
        memory_type == "technical_fact" -> 0.82
        true -> 0.70
      end

    relevance =
      cond do
        String.length(capture.content) > 80 -> 0.78
        String.length(capture.content) > 20 -> 0.66
        true -> 0.55
      end

    %{
      memory_type: MemoryTypes.normalize(memory_type),
      confidence: confidence,
      relevance: relevance
    }
  end

  defp store(capture, classify, opts) do
    budget = Keyword.get(opts, :budget, %{session: 50, project: 200})
    session_cap = Map.get(budget, :session, 50)
    project_cap = Map.get(budget, :project, 200)

    session_count = increment_session(capture.session_id)
    project_count = increment_project(capture.project_id)

    cond do
      session_count > session_cap ->
        %{
          status: :skipped_budget,
          reason: :session_budget_exceeded,
          memory_type: classify.memory_type
        }

      project_count > project_cap ->
        %{
          status: :skipped_budget,
          reason: :project_budget_exceeded,
          memory_type: classify.memory_type
        }

      true ->
        _ = Memory.record_session(capture.content, session_id: capture.session_id)
        %{status: :stored, reason: :ok, memory_type: classify.memory_type}
    end
  end

  defp recall(capture, opts) do
    storage = Keyword.get(opts, :storage, Pincer.Ports.Storage)
    embedding_fun = Keyword.get(opts, :embedding_fun, fn _ -> {:ok, [0.0]} end)

    history = [%{"role" => "user", "content" => capture.query || capture.content}]

    MemoryRecall.build(history,
      storage: storage,
      embedding_fun: embedding_fun,
      session_id: capture.session_id,
      emit_telemetry?: false
    )
  end

  defp compact(capture, _opts) do
    key = {:last_compact, capture.session_id}
    now = System.system_time(:second)
    last = lookup_counter(key)

    if is_integer(last) and now - last < 1 do
      %{status: :noop, reason: :recently_compacted}
    else
      put_counter(key, now)
      %{status: :compacted, reason: :window_rollup}
    end
  end

  defp explain(capture, recall) do
    %{
      recall_reason: if(recall.recall?, do: :query_eligible, else: :query_ineligible),
      query: capture.query,
      hit_count: length(recall.hits)
    }
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:set, :named_table, :public])
        :ok

      _ ->
        :ok
    end
  end

  defp increment_session(session_id) do
    bump_counter({:session, session_id})
  end

  defp increment_project(project_id) do
    bump_counter({:project, project_id})
  end

  defp bump_counter(key) do
    with_table(fn ->
      :ets.update_counter(@table, key, {2, 1}, {key, 0})
    end)
  end

  defp lookup_counter(key) do
    with_table(fn ->
      case :ets.lookup(@table, key) do
        [{^key, value}] -> value
        _ -> nil
      end
    end)
  end

  defp put_counter(key, value) do
    with_table(fn ->
      :ets.insert(@table, {key, value})
    end)
  end

  defp with_table(fun) when is_function(fun, 0) do
    ensure_table()

    try do
      fun.()
    rescue
      ArgumentError ->
        ensure_table()
        fun.()
    end
  end
end
