defmodule Pincer.Core.Introspection.Kernel do
  @moduledoc """
  Consciousness Kernel — dedicated GenServer for agent introspection.

  One Kernel per `agent_id` orchestrates reflection, lesson extraction,
  and wakefulness state transitions on its own tick loop (default: 10 min),
  decoupling introspection from Session.Server's heartbeat.

  ## Tick loop

  Every tick the kernel evaluates whether to trigger a reflection cycle:
  1. Checks guards (pending reflection, stall hold, throttle, trace depth)
  2. Transitions wakefulness to `:reflecting`
  3. Launches async `Reflection.reflect/3`
  4. On completion, updates SelfState and broadcasts to registered sessions

  ## Stall detection

  Maintains a ring buffer of the last 5 reflection summaries. If 3
  consecutive summaries are identical (normalized), reflection is held
  for 10 minutes to avoid wasting LLM calls.

  ## Session integration

  Sessions register via `register_session/2` and receive
  `{:kernel_self_state_updated, self_state}` messages on state changes.
  Sessions forward traces via `report_trace/2` and query lessons via
  `get_lesson_ids/1`.
  """
  use GenServer, restart: :transient
  require Logger

  alias Pincer.Core.AgentPaths
  alias Pincer.Core.Introspection.LessonExtractor
  alias Pincer.Core.Introspection.LessonStore
  alias Pincer.Core.Introspection.Mood
  alias Pincer.Core.Introspection.SelfState
  alias Pincer.Core.Introspection.Reflection

  @default_tick_interval 600_000
  @default_reflection_throttle 300_000
  @default_skill_promotion_throttle 300_000
  @stall_threshold 3
  @stall_hold_ms 600_000
  @max_reflection_history 5

  # --- Public API ---

  @doc """
  Ensures a Kernel is running for the given agent. Idempotent.
  """
  @spec ensure_started(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(agent_id, opts \\ []) do
    case Registry.lookup(__MODULE__.Registry, agent_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        __MODULE__.Supervisor.start_kernel(agent_id, opts)
    end
  end

  @doc "Registers a session PID to receive kernel updates. Monitored for auto-cleanup."
  @spec register_session(String.t(), pid()) :: :ok
  def register_session(agent_id, session_pid) do
    GenServer.cast(via(agent_id), {:register_session, session_pid})
  end

  @doc "Unregisters a session PID."
  @spec unregister_session(String.t(), pid()) :: :ok
  def unregister_session(agent_id, session_pid) do
    GenServer.cast(via(agent_id), {:unregister_session, session_pid})
  end

  @doc "Reports an executor trace for introspection processing."
  @spec report_trace(String.t(), map(), keyword()) :: :ok
  def report_trace(agent_id, trace_meta, opts \\ [])
      when is_map(trace_meta) and is_list(opts) do
    GenServer.cast(via(agent_id), {:report_trace, trace_meta, opts})
  end

  @doc "Reports session activity change for wakefulness FSM."
  @spec report_activity(String.t(), :working | :idle) :: :ok
  def report_activity(agent_id, activity) when activity in [:working, :idle] do
    GenServer.cast(via(agent_id), {:report_activity, activity})
  end

  @doc "Returns the current SelfState for prompt assembly."
  @spec get_self_state(String.t()) :: map() | nil
  def get_self_state(agent_id) do
    GenServer.call(via(agent_id), :get_self_state)
  catch
    :exit, _ -> nil
  end

  @doc "Returns IDs of top lessons for outcome tracking."
  @spec get_lesson_ids(String.t()) :: [binary()]
  def get_lesson_ids(agent_id) do
    GenServer.call(via(agent_id), :get_lesson_ids)
  catch
    :exit, _ -> []
  end

  @doc "Triggers asynchronous evaluation of eligible lessons for promotion into workspace skills."
  @spec promote_skills(String.t()) :: :ok
  def promote_skills(agent_id) do
    GenServer.cast(via(agent_id), :promote_skills)
  end

  # --- Lifecycle ---

  def start_link(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)
    GenServer.start_link(__MODULE__, opts, name: via(agent_id))
  end

  @impl true
  def init(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)
    tick_interval = Keyword.get(opts, :tick_interval, @default_tick_interval)
    reflection_throttle = Keyword.get(opts, :reflection_throttle_ms, @default_reflection_throttle)

    skill_promotion_throttle =
      Keyword.get(opts, :skill_promotion_throttle_ms, @default_skill_promotion_throttle)

    introspection_client = Keyword.get(opts, :introspection_client)
    workspace_path = Keyword.get(opts, :workspace_path, AgentPaths.workspace_root(agent_id))

    skill_generator =
      Keyword.get_lazy(opts, :skill_generator, fn ->
        Application.fetch_env!(:pincer, :introspection_skill_generator)
      end)

    skill_promotion_enabled? =
      Keyword.get(
        opts,
        :skill_promotion_enabled?,
        Application.get_env(:pincer, :enable_skill_promotion, true)
      )

    self_state =
      case SelfState.load_or_create(agent_id) do
        {:ok, s} -> s
        {:error, _} -> nil
      end

    state = %{
      agent_id: agent_id,
      workspace_path: workspace_path,
      self_state: self_state,
      wakefulness: :idle,
      tick_interval: tick_interval,
      reflection_throttle_ms: reflection_throttle,
      last_reflection_at: nil,
      last_trace: nil,
      pending_reflection?: false,
      skill_promotion_enabled?: skill_promotion_enabled?,
      skill_promotion_throttle_ms: skill_promotion_throttle,
      last_skill_promotion_at: nil,
      pending_skill_promotion?: false,
      skill_generator: skill_generator,
      reflection_history: [],
      stall_hold_until: nil,
      session_pids: MapSet.new(),
      session_monitors: %{},
      introspection_client: introspection_client,
      last_session_override: nil
    }

    schedule_tick(tick_interval)

    Logger.info("[KERNEL] #{agent_id} started (tick=#{tick_interval}ms)")
    {:ok, state}
  end

  # --- Tick loop ---

  @impl true
  def handle_info(:tick, state) do
    schedule_tick(state.tick_interval)
    state = apply_mood_decay(state)
    state = maybe_reflect(state)
    {:noreply, state}
  end

  # --- Reflection complete ---

  @impl true
  def handle_info({:reflection_complete, {:ok, %{action: :skip}}}, state) do
    {:noreply, %{state | pending_reflection?: false, last_reflection_at: now()}}
  end

  @impl true
  def handle_info({:reflection_complete, {:ok, result}}, state) do
    summary = result[:summary] || result["summary"] || ""
    result = blend_mood_from_reflection(state.self_state, result)

    case SelfState.update(state.agent_id, result) do
      {:ok, updated} ->
        new_history = push_history(state.reflection_history, summary)
        new_wakefulness = if MapSet.size(state.session_pids) > 0, do: :active, else: :idle

        stall_hold =
          case check_stall(new_history) do
            :stalled ->
              Logger.info("[KERNEL] #{state.agent_id} stall detected, holding reflection")
              now() + @stall_hold_ms

            :ok ->
              state.stall_hold_until
          end

        broadcast(state.session_pids, {:kernel_self_state_updated, updated})

        next_state = %{
          state
          | self_state: updated,
            pending_reflection?: false,
            wakefulness: new_wakefulness,
            last_reflection_at: now(),
            reflection_history: new_history,
            stall_hold_until: stall_hold
        }

        {:noreply, maybe_promote_skills(next_state, false)}

      {:error, reason} ->
        Logger.warning("[KERNEL] #{state.agent_id} self-state update failed: #{inspect(reason)}")
        {:noreply, %{state | pending_reflection?: false, last_reflection_at: now()}}
    end
  end

  @impl true
  def handle_info({:reflection_complete, {:error, reason}}, state) do
    Logger.warning("[KERNEL] #{state.agent_id} reflection failed: #{inspect(reason)}")
    {:noreply, %{state | pending_reflection?: false, last_reflection_at: now()}}
  end

  @impl true
  def handle_info({:skill_promotion_complete, {:ok, %{name: skill_name} = skill}}, state) do
    Logger.info("[KERNEL] #{state.agent_id} promoted skill #{skill_name}")
    broadcast(state.session_pids, {:kernel_skills_updated, skill})

    {:noreply,
     %{
       state
       | pending_skill_promotion?: false,
         last_skill_promotion_at: now()
     }}
  end

  @impl true
  def handle_info({:skill_promotion_complete, {:ok, :no_eligible_lessons}}, state) do
    {:noreply, %{state | pending_skill_promotion?: false}}
  end

  @impl true
  def handle_info({:skill_promotion_complete, {:error, reason}}, state) do
    Logger.warning("[KERNEL] #{state.agent_id} skill promotion failed: #{inspect(reason)}")
    {:noreply, %{state | pending_skill_promotion?: false}}
  end

  # --- Session monitoring ---

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {state, _} = remove_session(state, pid)
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # --- Casts ---

  @impl true
  def handle_cast({:register_session, pid}, state) do
    if MapSet.member?(state.session_pids, pid) do
      {:noreply, state}
    else
      ref = Process.monitor(pid)

      {:noreply,
       %{
         state
         | session_pids: MapSet.put(state.session_pids, pid),
           session_monitors: Map.put(state.session_monitors, pid, ref)
       }}
    end
  end

  @impl true
  def handle_cast({:unregister_session, pid}, state) do
    {state, _} = remove_session(state, pid)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:report_trace, trace_meta}, state) do
    handle_cast({:report_trace, trace_meta, []}, state)
  end

  def handle_cast({:report_trace, trace_meta, cast_opts}, state) do
    session_override =
      Keyword.get(cast_opts, :session_model_override) || extract_session_override(trace_meta)

    state = %{state | last_trace: trace_meta, last_session_override: session_override}
    classification = Reflection.classify(trace_meta)

    # Async lesson extraction for non-trivial traces
    case classification do
      :shallow ->
        :ok

      _ ->
        agent_id = state.agent_id
        opts = introspection_call_opts(state, trace_meta)

        Task.start(fn ->
          LessonExtractor.extract(agent_id, trace_meta, opts)
        end)

        # New evidence clears stall hold
        if state.stall_hold_until do
          Logger.info("[KERNEL] #{state.agent_id} stall hold cleared by new trace")
        end
    end

    stall_hold = if classification != :shallow, do: nil, else: state.stall_hold_until
    state = apply_mood_from_trace(state, classification)

    {:noreply, %{state | stall_hold_until: stall_hold}}
  end

  @impl true
  def handle_cast({:report_activity, :working}, state) do
    new_wakefulness = if state.pending_reflection?, do: :reflecting, else: :active
    {:noreply, %{state | wakefulness: new_wakefulness}}
  end

  @impl true
  def handle_cast({:report_activity, :idle}, state) do
    new_wakefulness = if state.pending_reflection?, do: :reflecting, else: :idle
    {:noreply, %{state | wakefulness: new_wakefulness}}
  end

  @impl true
  def handle_cast(:promote_skills, state) do
    {:noreply, maybe_promote_skills(state, true)}
  end

  # --- Calls ---

  @impl true
  def handle_call(:get_self_state, _from, state) do
    {:reply, state.self_state, state}
  end

  @impl true
  def handle_call(:get_lesson_ids, _from, state) do
    ids =
      LessonStore.top_lessons(state.agent_id, 5, min_confidence: 0.4)
      |> Enum.map(& &1.id)

    {:reply, ids, state}
  rescue
    _ -> {:reply, [], state}
  end

  # --- Private ---

  defp apply_mood_decay(%{self_state: nil} = state), do: state

  defp apply_mood_decay(state) do
    v = state.self_state.mood_valence || 0.0
    a = state.self_state.mood_arousal || 0.0
    {new_v, new_a} = Mood.decay(v, a)

    if new_v != v or new_a != a do
      case SelfState.update(state.agent_id, %{mood_valence: new_v, mood_arousal: new_a}) do
        {:ok, updated} -> %{state | self_state: updated}
        _ -> state
      end
    else
      state
    end
  end

  defp blend_mood_from_reflection(nil, result), do: result

  defp blend_mood_from_reflection(self_state, result) do
    case {result[:mood_valence], result[:mood_arousal]} do
      {llm_v, llm_a} when is_number(llm_v) and is_number(llm_a) ->
        cur_v = self_state.mood_valence || 0.0
        cur_a = self_state.mood_arousal || 0.0
        {blended_v, blended_a} = Mood.blend_llm(cur_v, cur_a, llm_v, llm_a)
        Map.merge(result, %{mood_valence: blended_v, mood_arousal: blended_a})

      _ ->
        result
    end
  end

  defp apply_mood_from_trace(%{self_state: nil} = state, _classification), do: state
  defp apply_mood_from_trace(state, :shallow), do: state

  defp apply_mood_from_trace(state, classification) do
    outcome = if classification == :failure, do: :failure, else: :success
    v = state.self_state.mood_valence || 0.0
    a = state.self_state.mood_arousal || 0.0
    {new_v, new_a} = Mood.from_outcome(outcome, v, a)

    case SelfState.update(state.agent_id, %{mood_valence: new_v, mood_arousal: new_a}) do
      {:ok, updated} -> %{state | self_state: updated}
      _ -> state
    end
  end

  defp maybe_reflect(state) do
    now = now()

    cond do
      state.pending_reflection? ->
        state

      stall_held?(state.stall_hold_until, now) ->
        state

      is_nil(state.last_trace) or is_nil(state.self_state) ->
        state

      not throttle_expired?(state.last_reflection_at, state.reflection_throttle_ms, now) ->
        state

      Reflection.classify(state.last_trace) == :shallow ->
        state

      true ->
        Logger.info("[KERNEL] #{state.agent_id} triggering reflection")
        kernel_pid = self()
        trace = state.last_trace
        self_state = state.self_state
        opts = introspection_call_opts(state, trace)

        Task.start(fn ->
          result = Reflection.reflect(trace, self_state, opts)
          send(kernel_pid, {:reflection_complete, result})
        end)

        %{state | pending_reflection?: true, wakefulness: :reflecting}
    end
  end

  defp maybe_promote_skills(state, force?) do
    current_time = now()

    cond do
      not state.skill_promotion_enabled? ->
        state

      state.pending_skill_promotion? ->
        state

      not force? and
          not throttle_expired?(
            state.last_skill_promotion_at,
            state.skill_promotion_throttle_ms,
            current_time
          ) ->
        state

      true ->
        kernel_pid = self()
        agent_id = state.agent_id
        generator = state.skill_generator

        opts =
          [workspace_path: state.workspace_path]
          |> then(fn acc ->
            if state.introspection_client do
              Keyword.put(acc, :introspection_client, state.introspection_client)
            else
              acc
            end
          end)

        Task.start(fn ->
          result =
            try do
              generator.promote(agent_id, opts)
            rescue
              e -> {:error, {:exception, Exception.message(e)}}
            catch
              :exit, reason -> {:error, {:exit, reason}}
            end

          send(kernel_pid, {:skill_promotion_complete, result})
        end)

        %{state | pending_skill_promotion?: true}
    end
  end

  defp stall_held?(nil, _now), do: false
  defp stall_held?(hold_until, now), do: now < hold_until

  defp throttle_expired?(nil, _throttle, _now), do: true
  defp throttle_expired?(last, throttle, now), do: now - last >= throttle

  defp check_stall(history) do
    recent = Enum.take(history, @stall_threshold)

    if length(recent) >= @stall_threshold and
         recent |> Enum.uniq_by(&normalize/1) |> length() == 1 do
      :stalled
    else
      :ok
    end
  end

  defp normalize(summary) do
    summary |> String.downcase() |> String.trim() |> String.slice(0, 200)
  end

  defp push_history(history, summary) do
    [summary | history] |> Enum.take(@max_reflection_history)
  end

  defp remove_session(state, pid) do
    case Map.pop(state.session_monitors, pid) do
      {nil, monitors} ->
        {%{state | session_monitors: monitors}, nil}

      {ref, monitors} ->
        Process.demonitor(ref, [:flush])

        {%{
           state
           | session_pids: MapSet.delete(state.session_pids, pid),
             session_monitors: monitors
         }, ref}
    end
  end

  defp broadcast(session_pids, message) do
    Enum.each(session_pids, fn pid ->
      send(pid, message)
    end)
  end

  defp schedule_tick(interval) do
    Process.send_after(self(), :tick, interval)
  end

  defp now, do: System.system_time(:millisecond)

  defp via(agent_id), do: {:via, Registry, {__MODULE__.Registry, agent_id}}

  defp introspection_call_opts(state, trace_meta) do
    override = extract_session_override(trace_meta) || Map.get(state, :last_session_override)

    []
    |> then(fn acc ->
      if state.introspection_client,
        do: Keyword.put(acc, :introspection_client, state.introspection_client),
        else: acc
    end)
    |> then(fn acc ->
      if override, do: Keyword.put(acc, :session_model_override, override), else: acc
    end)
  end

  defp extract_session_override(trace_meta) when is_map(trace_meta) do
    Map.get(trace_meta, "session_model_override") || Map.get(trace_meta, :session_model_override)
  end

  defp extract_session_override(_), do: nil
end
