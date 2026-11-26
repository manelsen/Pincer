defmodule Pincer.Core.Session.BlackboardIngestor do
  @moduledoc """
  Handles Blackboard polling, scoped recovery catch-up, sub-agent progress
  broadcasts, and history ingestion for `Pincer.Core.Session.Server`.
  """

  alias Pincer.Core.Orchestration.Blackboard
  alias Pincer.Core.Session.Blackboard, as: SessionBlackboard
  alias Pincer.Infra.PubSub

  @task_supervisor Pincer.Core.TaskSupervisor

  @doc """
  Spawns an asynchronous catch-up task that fetches missed Blackboard messages
  for `state.blackboard_scope` and notifies `parent_pid` when new messages exist.
  """
  @spec start_recovery_catch_up(map(), pid(), keyword()) :: :ok
  def start_recovery_catch_up(state, parent_pid \\ self(), opts \\ []) do
    task_supervisor = Keyword.get(opts, :task_supervisor, @task_supervisor)
    blackboard = Keyword.get(opts, :blackboard, Blackboard)
    since_id = state.last_blackboard_id
    scope = state.blackboard_scope

    {:ok, _pid} =
      Task.Supervisor.start_child(task_supervisor, fn ->
        case blackboard.fetch_new(since_id, scope: scope) do
          {[], _} ->
            :ok

          {messages, new_last_id} ->
            send(parent_pid, {:recovery_catch_up_done, messages, new_last_id})
        end
      end)

    :ok
  end

  @doc """
  Polls the Blackboard for new scoped updates and ingests them into `state`.
  """
  @spec poll(map(), keyword()) :: {:noop | :ok | :evaluate, map()}
  def poll(state, opts \\ []) do
    blackboard = Keyword.get(opts, :blackboard, Blackboard)

    case blackboard.fetch_new(state.last_blackboard_id, scope: state.blackboard_scope) do
      {[], _} ->
        {:noop, state}

      {messages, new_last_id} ->
        ingest_batch(messages, new_last_id, state, Keyword.put_new(opts, :broadcast?, true))
    end
  end

  @doc """
  Ingests a batch of Blackboard messages into `state`, optionally broadcasting
  sub-agent notifications and requesting an unsolicited LLM evaluation.
  """
  @spec ingest_batch([map()], integer(), map(), keyword()) :: {:ok | :evaluate, map()}
  def ingest_batch(messages, new_last_id, state, opts \\ []) do
    broadcast? = Keyword.get(opts, :broadcast?, true)

    publish_fn =
      Keyword.get(opts, :publish_fn, fn sid, event ->
        PubSub.broadcast("session:#{sid}", event)
      end)

    %{
      history: new_history,
      tracker: tracker,
      notifications: notifications,
      needs_review?: review?
    } = SessionBlackboard.ingest(state.history, state.subagent_progress_tracker, messages)

    if broadcast? do
      Enum.each(notifications, &publish_fn.(state.session_id, {:agent_status, &1}))
    end

    next_state = %{
      state
      | history: new_history,
        last_blackboard_id: new_last_id,
        subagent_progress_tracker: tracker
    }

    if broadcast? and state.status == :idle and review? do
      {:evaluate, next_state}
    else
      {:ok, next_state}
    end
  end
end
