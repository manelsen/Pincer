defmodule Pincer.Core.CircuitBreaker do
  @moduledoc """
  Circuit breaker per LLM provider / external service.

  States:
  - `:closed` — normal operation, requests pass through
  - `:open` — circuit tripped, requests fail immediately
  - `:half_open` — testing recovery, one probe request allowed

  Configuration (per provider, in config.yaml or Application env):
  - failure_threshold: number of consecutive failures before opening (default: 5)
  - recovery_timeout_ms: time in open state before trying half_open (default: 30_000)
  - probe_timeout_ms: how long half_open waits for probe result (default: 10_000)

  The ETS table is `:protected` and owned by this GenServer (with `ETSTableHeir`
  as heir). All state transitions are serialized through the GenServer while
  caller functions execute outside `GenServer.call/3` to avoid deadlocks on slow
  I/O or nested calls.

  Usage:
      CircuitBreaker.call("openrouter", fn -> LLM.Client.chat_completion(msgs, opts) end)
  """
  use GenServer

  require Logger

  alias Pincer.Utils.ETSHelper
  alias Pincer.Utils.ETSTableHeir

  @table :pincer_circuit_breaker
  @default_failure_threshold 5
  @default_recovery_timeout 30_000
  @default_probe_timeout 10_000

  defstruct [
    :name,
    state: :closed,
    failure_count: 0,
    last_failure_at: nil,
    success_count: 0
  ]

  @doc "Starts the CircuitBreaker GenServer."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @impl true
  def init(_opts) do
    _ =
      ETSHelper.ensure_named_table(@table,
        options: [:named_table, :set, :protected, read_concurrency: true]
      )

    :ok = ETSTableHeir.ensure_owned(@table)
    {:ok, %{probes: %{}, monitors: %{}}}
  end

  @doc """
  Execute `fun` if the circuit is closed or grants the single half-open probe.
  Records success/failure and transitions state accordingly.

  `fun` runs in the caller process outside the GenServer lock so slow I/O and
  nested or recursive `call/3` invocations cannot deadlock.
  """
  @spec call(String.t(), (-> any()), keyword()) :: any()
  def call(name, fun, opts \\ []) when is_function(fun, 0) do
    case safe_call({:acquire, name, self(), opts}) do
      {:ok, _mode, probe_ref} ->
        execute_and_record(name, fun, probe_ref, opts)

      {:error, {:circuit_open, ^name}} = open_err ->
        open_err

      {:error, :circuit_breaker_unavailable} ->
        fun.()
    end
  end

  @doc "Returns the current state of the circuit for a given name."
  @spec state(String.t(), keyword()) :: :closed | :open | :half_open
  def state(name, opts \\ []) do
    case :ets.whereis(@table) do
      :undefined ->
        :closed

      _tid ->
        case :ets.lookup(@table, name) do
          [{^name, %__MODULE__{} = cb}] -> effective_state(cb, opts)
          [] -> :closed
        end
    end
  end

  @doc "Manually reset a circuit to closed state (admin action)."
  @spec reset(String.t()) :: :ok
  def reset(name) do
    case safe_call({:reset, name}) do
      :ok ->
        Logger.info("CircuitBreaker: #{name} manually reset to closed")
        :ok

      {:error, :circuit_breaker_unavailable} ->
        :ok
    end
  end

  @doc "Returns a summary of all circuit states."
  @spec summary() :: [{String.t(), :closed | :open | :half_open, non_neg_integer()}]
  def summary do
    case :ets.whereis(@table) do
      :undefined ->
        []

      _tid ->
        :ets.tab2list(@table)
        |> Enum.map(fn {name, cb} -> {name, effective_state(cb, []), cb.failure_count} end)
    end
  end

  # --- GenServer Callbacks ---

  @impl true
  def handle_call({:acquire, name, caller_pid, opts}, _from, state) do
    cb = get_or_init(name)
    now = System.monotonic_time(:millisecond)
    recovery_timeout = recovery_timeout_ms(opts)
    probe_timeout = probe_timeout_ms(opts)

    case cb.state do
      :closed ->
        {:reply, {:ok, :closed, nil}, state}

      :open ->
        if cb.last_failure_at != nil and now - cb.last_failure_at >= recovery_timeout do
          grant_probe(cb, name, caller_pid, now, state)
        else
          {:reply, {:error, {:circuit_open, name}}, state}
        end

      :half_open ->
        case Map.get(state.probes, name) do
          nil ->
            grant_probe(cb, name, caller_pid, now, state)

          %{mon_ref: old_mon, pid: old_pid, started_at: started_at} ->
            if not Process.alive?(old_pid) or now - started_at >= probe_timeout do
              state = drop_probe(state, name, old_mon)
              grant_probe(cb, name, caller_pid, now, state)
            else
              {:reply, {:error, {:circuit_open, name}}, state}
            end
        end
    end
  end

  @impl true
  def handle_call({:record_success, name, probe_ref}, _from, state) do
    cb = get_or_init(name)

    cond do
      cb.state == :half_open and probe_ref != nil ->
        if matching_probe?(state, name, probe_ref) do
          state = clear_probe(state, name)
          updated = %{cb | state: :closed, failure_count: 0, success_count: cb.success_count + 1}
          :ets.insert(@table, {name, updated})
          {:reply, :ok, state}
        else
          {:reply, :ok, state}
        end

      cb.state == :closed and probe_ref == nil ->
        updated = %{cb | state: :closed, failure_count: 0, success_count: cb.success_count + 1}
        :ets.insert(@table, {name, updated})
        {:reply, :ok, state}

      true ->
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:record_failure, name, reason, probe_ref, opts}, _from, state) do
    cb = get_or_init(name)
    threshold = failure_threshold(opts)
    now_mono = System.monotonic_time(:millisecond)

    cond do
      cb.state == :half_open and probe_ref != nil ->
        if matching_probe?(state, name, probe_ref) do
          state = clear_probe(state, name)
          open_circuit(name, cb, cb.failure_count + 1, now_mono, reason)
          {:reply, :ok, state}
        else
          {:reply, :ok, state}
        end

      cb.state == :closed and probe_ref == nil ->
        new_count = cb.failure_count + 1

        if new_count >= threshold do
          open_circuit(name, cb, new_count, now_mono, reason)
        else
          :ets.insert(@table, {name, %{cb | failure_count: new_count, last_failure_at: now_mono}})
        end

        {:reply, :ok, state}

      cb.state == :open and probe_ref == nil ->
        :ets.insert(@table, {name, %{cb | failure_count: cb.failure_count + 1}})
        {:reply, :ok, state}

      true ->
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:reset, name}, _from, state) do
    state = clear_probe(state, name)
    :ets.delete(@table, name)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, mon_ref, :process, _pid, reason}, state) do
    case Map.pop(state.monitors, mon_ref) do
      {nil, monitors} ->
        {:noreply, %{state | monitors: monitors}}

      {{name, probe_ref}, monitors} ->
        state = %{state | monitors: monitors}

        state =
          if matching_probe?(state, name, probe_ref) do
            cb = get_or_init(name)
            now_mono = System.monotonic_time(:millisecond)
            probes = Map.delete(state.probes, name)

            if cb.state == :half_open do
              open_circuit(name, cb, cb.failure_count + 1, now_mono, {:probe_down, reason})
            end

            %{state | probes: probes}
          else
            state
          end

        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # --- Private ---

  defp execute_and_record(name, fun, probe_ref, opts) do
    try do
      result = fun.()
      _ = safe_call({:record_success, name, probe_ref})
      result
    catch
      kind, reason ->
        stacktrace = __STACKTRACE__
        formatted = format_failure(kind, reason, stacktrace)
        _ = safe_call({:record_failure, name, formatted, probe_ref, opts})
        :erlang.raise(kind, reason, stacktrace)
    end
  end

  defp safe_call(message) do
    GenServer.call(__MODULE__, message)
  catch
    :exit, {:noproc, _} -> {:error, :circuit_breaker_unavailable}
  end

  defp format_failure(:error, reason, stacktrace) do
    Exception.normalize(:error, reason, stacktrace)
  end

  defp format_failure(kind, reason, _stacktrace), do: {kind, reason}

  defp grant_probe(cb, name, caller_pid, now, state) do
    probe_ref = make_ref()
    mon_ref = Process.monitor(caller_pid)
    :ets.insert(@table, {name, %{cb | state: :half_open}})

    probe = %{ref: probe_ref, mon_ref: mon_ref, pid: caller_pid, started_at: now}
    probes = Map.put(state.probes, name, probe)
    monitors = Map.put(state.monitors, mon_ref, {name, probe_ref})

    {:reply, {:ok, :half_open, probe_ref}, %{state | probes: probes, monitors: monitors}}
  end

  defp matching_probe?(state, name, probe_ref) do
    match?(%{ref: ^probe_ref}, Map.get(state.probes, name))
  end

  defp clear_probe(state, name) do
    case Map.pop(state.probes, name) do
      {nil, _probes} ->
        state

      {%{mon_ref: mon_ref}, probes} ->
        Process.demonitor(mon_ref, [:flush])
        monitors = Map.delete(state.monitors, mon_ref)
        %{state | probes: probes, monitors: monitors}
    end
  end

  defp drop_probe(state, name, mon_ref) do
    Process.demonitor(mon_ref, [:flush])

    %{
      state
      | probes: Map.delete(state.probes, name),
        monitors: Map.delete(state.monitors, mon_ref)
    }
  end

  defp open_circuit(name, cb, new_count, now_mono, reason) do
    Logger.warning(
      "CircuitBreaker: #{name} OPENED after #{new_count} failures. Reason: #{inspect(reason)}"
    )

    updated = %{
      cb
      | state: :open,
        failure_count: new_count,
        last_failure_at: now_mono
    }

    :ets.insert(@table, {name, updated})
  end

  defp effective_state(%__MODULE__{state: :open, last_failure_at: last_at}, opts)
       when not is_nil(last_at) do
    if System.monotonic_time(:millisecond) - last_at >= recovery_timeout_ms(opts) do
      :half_open
    else
      :open
    end
  end

  defp effective_state(%__MODULE__{state: state}, _opts), do: state

  defp get_or_init(name) do
    case :ets.lookup(@table, name) do
      [{^name, cb}] -> cb
      [] -> %__MODULE__{name: name}
    end
  end

  defp failure_threshold(opts) do
    Keyword.get(
      opts,
      :failure_threshold,
      Application.get_env(:pincer, :circuit_breaker_threshold, @default_failure_threshold)
    )
  end

  defp recovery_timeout_ms(opts) do
    Keyword.get(
      opts,
      :recovery_timeout_ms,
      Application.get_env(:pincer, :circuit_breaker_recovery_ms, @default_recovery_timeout)
    )
  end

  defp probe_timeout_ms(opts) do
    Keyword.get(
      opts,
      :probe_timeout_ms,
      Application.get_env(:pincer, :circuit_breaker_probe_ms, @default_probe_timeout)
    )
  end
end
