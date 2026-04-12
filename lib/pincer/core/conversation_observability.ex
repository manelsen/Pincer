defmodule Pincer.Core.ConversationObservability do
  @moduledoc """
  In-memory aggregator for conversation telemetry.

  Subscribes to `:telemetry` events emitted by `Pincer.Core.Telemetry` and
  maintains a real-time snapshot of conversation health metrics:

  - Active sessions (started minus stopped)
  - Total turns completed and errored
  - Running totals for prompt/completion tokens
  - Per-session turn latency (last observed)

  The snapshot is available via `snapshot/0` and is reset via `reset/0`.
  It is intentionally in-memory only — not persisted to the database.
  """

  use GenServer

  require Logger

  @handler_id "pincer-conversation-observability"

  @events [
    [:pincer, :conversation, :session, :start],
    [:pincer, :conversation, :session, :stop],
    [:pincer, :conversation, :turn, :start],
    [:pincer, :conversation, :turn, :stop],
    [:pincer, :conversation, :turn, :error]
  ]

  @type snapshot :: %{
          active_sessions: non_neg_integer(),
          sessions_started: non_neg_integer(),
          sessions_stopped: non_neg_integer(),
          turns_completed: non_neg_integer(),
          turns_errored: non_neg_integer(),
          total_prompt_tokens: non_neg_integer(),
          total_completion_tokens: non_neg_integer(),
          total_turn_duration_ms: non_neg_integer(),
          last_turn_duration_ms: non_neg_integer() | nil
        }

  @doc "Starts the observability aggregator."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc "Returns the current conversation observability snapshot."
  @spec snapshot() :: snapshot()
  def snapshot do
    GenServer.call(__MODULE__, :snapshot)
  end

  @doc "Resets all counters."
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

    {:ok, initial_state()}
  end

  @impl true
  def terminate(_reason, _state) do
    :telemetry.detach(@handler_id)
    :ok
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    snap = %{
      active_sessions: max(0, state.sessions_started - state.sessions_stopped),
      sessions_started: state.sessions_started,
      sessions_stopped: state.sessions_stopped,
      turns_completed: state.turns_completed,
      turns_errored: state.turns_errored,
      total_prompt_tokens: state.total_prompt_tokens,
      total_completion_tokens: state.total_completion_tokens,
      total_turn_duration_ms: state.total_turn_duration_ms,
      last_turn_duration_ms: state.last_turn_duration_ms
    }

    {:reply, snap, state}
  end

  def handle_call(:reset, _from, _state) do
    {:reply, :ok, initial_state()}
  end

  @impl true
  def handle_cast({:telemetry, [:pincer, :conversation, :session, :start], _m, _meta}, state) do
    {:noreply, %{state | sessions_started: state.sessions_started + 1}}
  end

  def handle_cast({:telemetry, [:pincer, :conversation, :session, :stop], _m, _meta}, state) do
    {:noreply, %{state | sessions_stopped: state.sessions_stopped + 1}}
  end

  def handle_cast({:telemetry, [:pincer, :conversation, :turn, :start], _m, _meta}, state) do
    {:noreply, state}
  end

  def handle_cast(
        {:telemetry, [:pincer, :conversation, :turn, :stop], measurements, _meta},
        state
      ) do
    duration = Map.get(measurements, :duration_ms, 0)
    prompt = Map.get(measurements, :prompt_tokens, 0)
    completion = Map.get(measurements, :completion_tokens, 0)

    {:noreply,
     %{
       state
       | turns_completed: state.turns_completed + 1,
         total_prompt_tokens: state.total_prompt_tokens + prompt,
         total_completion_tokens: state.total_completion_tokens + completion,
         total_turn_duration_ms: state.total_turn_duration_ms + duration,
         last_turn_duration_ms: duration
     }}
  end

  def handle_cast({:telemetry, [:pincer, :conversation, :turn, :error], _m, _meta}, state) do
    {:noreply, %{state | turns_errored: state.turns_errored + 1}}
  end

  def handle_cast({:telemetry, _event, _measurements, _metadata}, state) do
    {:noreply, state}
  end

  defp initial_state do
    %{
      sessions_started: 0,
      sessions_stopped: 0,
      turns_completed: 0,
      turns_errored: 0,
      total_prompt_tokens: 0,
      total_completion_tokens: 0,
      total_turn_duration_ms: 0,
      last_turn_duration_ms: nil
    }
  end
end
