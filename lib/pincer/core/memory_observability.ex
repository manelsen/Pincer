defmodule Pincer.Core.MemoryObservability do
  @moduledoc """
  Aggregates runtime memory telemetry into a deterministic local snapshot.

  This process is intentionally in-memory only. It tracks search and recall
  counters for diagnostics, tests, and future runtime inspection without
  storing query text or recalled content.
  """

  use GenServer

  @handler_id "pincer-memory-observability"
  @events [
    [:pincer, :memory, :search],
    [:pincer, :memory, :recall]
  ]

  @type snapshot :: %{
          search: map(),
          recall: map(),
          last_search: map() | nil,
          last_recall: map() | nil
        }

  @doc """
  Starts the in-memory observability aggregator.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc """
  Returns the current memory observability snapshot.
  """
  @spec snapshot() :: snapshot()
  def snapshot do
    GenServer.call(__MODULE__, :snapshot)
  end

  @doc """
  Resets all local counters and last-event snapshots.
  """
  @spec reset() :: :ok
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  @doc false
  def handle_event(event, measurements, metadata, server) do
    GenServer.cast(server, {:telemetry, event, measurements, metadata})
  end

  @impl true
  def init(:ok) do
    :telemetry.detach(@handler_id)

    :ok =
      :telemetry.attach_many(
        @handler_id,
        @events,
        &__MODULE__.handle_event/4,
        self()
      )

    {:ok, default_state()}
  end

  @impl true
  def terminate(_reason, _state) do
    :telemetry.detach(@handler_id)
    :ok
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, render_snapshot(state), state}
  end

  @impl true
  def handle_call(:reset, _from, _state) do
    {:reply, :ok, default_state()}
  end

  @impl true
  def handle_cast({:telemetry, [:pincer, :memory, :search], measurements, metadata}, state) do
    {:noreply, update_search(state, measurements, metadata)}
  end

  def handle_cast({:telemetry, [:pincer, :memory, :recall], measurements, metadata}, state) do
    {:noreply, update_recall(state, measurements, metadata)}
  end

  def handle_cast(_message, state) do
    {:noreply, state}
  end

  defp update_search(state, measurements, metadata) do
    source = Map.get(metadata, :source, :unknown)
    outcome = Map.get(metadata, :outcome, :ok)

    source_state =
      state.search.by_source
      |> Map.get(source, default_search_source())
      |> increment(:count, Map.get(measurements, :count, 1))
      |> increment(:total_hits, Map.get(measurements, :hit_count, 0))
      |> increment(:total_duration_ms, Map.get(measurements, :duration_ms, 0))
      |> maybe_increment(:skipped_count, outcome == :skipped)
      |> maybe_increment(:error_count, outcome == :error)

    search_state =
      state.search
      |> increment(:count, Map.get(measurements, :count, 1))
      |> increment(:total_hits, Map.get(measurements, :hit_count, 0))
      |> increment(:total_duration_ms, Map.get(measurements, :duration_ms, 0))
      |> Map.put(:by_source, Map.put(state.search.by_source, source, source_state))

    %{state | search: search_state, last_search: last_event(measurements, metadata)}
  end

  defp update_recall(state, measurements, metadata) do
    %{
      state
      | recall:
          state.recall
          |> increment(:count, Map.get(measurements, :count, 1))
          |> maybe_increment(:eligible_count, Map.get(metadata, :eligible, false))
          |> maybe_increment(:empty_count, Map.get(measurements, :total_hits, 0) == 0)
          |> increment(:total_hits, Map.get(measurements, :total_hits, 0))
          |> increment(:prompt_chars, Map.get(measurements, :prompt_chars, 0))
          |> increment(:learnings_count, Map.get(measurements, :learnings_count, 0))
          |> increment(:total_duration_ms, Map.get(measurements, :duration_ms, 0)),
        last_recall: last_event(measurements, metadata)
    }
  end

  defp render_snapshot(state) do
    %{
      search: %{
        count: state.search.count,
        total_hits: state.search.total_hits,
        avg_duration_ms: average(state.search.total_duration_ms, state.search.count),
        by_source:
          Map.new(state.search.by_source, fn {source, source_state} ->
            {source,
             %{
               count: source_state.count,
               total_hits: source_state.total_hits,
               avg_duration_ms: average(source_state.total_duration_ms, source_state.count),
               skipped_count: source_state.skipped_count,
               error_count: source_state.error_count
             }}
          end)
      },
      recall: %{
        count: state.recall.count,
        eligible_count: state.recall.eligible_count,
        empty_count: state.recall.empty_count,
        total_hits: state.recall.total_hits,
        prompt_chars: state.recall.prompt_chars,
        learnings_count: state.recall.learnings_count,
        avg_duration_ms: average(state.recall.total_duration_ms, state.recall.count)
      },
      last_search: state.last_search,
      last_recall: state.last_recall
    }
  end

  defp default_state do
    %{
      search: %{
        count: 0,
        total_hits: 0,
        total_duration_ms: 0,
        by_source: %{}
      },
      recall: %{
        count: 0,
        eligible_count: 0,
        empty_count: 0,
        total_hits: 0,
        prompt_chars: 0,
        learnings_count: 0,
        total_duration_ms: 0
      },
      last_search: nil,
      last_recall: nil
    }
  end

  defp default_search_source do
    %{
      count: 0,
      total_hits: 0,
      total_duration_ms: 0,
      skipped_count: 0,
      error_count: 0
    }
  end

  defp last_event(measurements, metadata) do
    measurements
    |> Map.merge(metadata)
    |> Map.delete(:count)
  end

  defp increment(map, key, value) do
    Map.update!(map, key, &(&1 + value))
  end

  defp maybe_increment(map, key, true), do: increment(map, key, 1)
  defp maybe_increment(map, _key, false), do: map

  defp average(_total, 0), do: 0.0
  defp average(total, count), do: total / count
end
