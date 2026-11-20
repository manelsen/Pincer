defmodule Pincer.Adapters.Tools.TimerServer do
  @moduledoc """
  Supervised GenServer managing volatile one-off timers scheduled via
  `Process.send_after/3` without blocking processes in `Process.sleep/1`.
  """

  use GenServer

  defstruct timers: %{}, registry: Pincer.Core.Session.Registry

  @doc "Starts the TimerServer GenServer."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Schedules a one-off `{:cron_trigger, prompt}` delivery after `delay_ms` milliseconds."
  @spec schedule(GenServer.server(), String.t(), String.t(), pos_integer()) ::
          {:ok, String.t()} | {:error, atom()}
  def schedule(server \\ __MODULE__, session_id, prompt, delay_ms)

  def schedule(_server, session_id, _prompt, _delay_ms)
      when not is_binary(session_id) or session_id == "" do
    {:error, :invalid_session_id}
  end

  def schedule(_server, _session_id, prompt, _delay_ms)
      when not is_binary(prompt) or prompt == "" do
    {:error, :invalid_prompt}
  end

  def schedule(_server, _session_id, _prompt, delay_ms)
      when not is_integer(delay_ms) or delay_ms <= 0 do
    {:error, :invalid_delay}
  end

  def schedule(server, session_id, prompt, delay_ms) do
    GenServer.call(server, {:schedule, session_id, prompt, delay_ms})
  end

  @doc "Cancels an active timer by ID."
  @spec cancel(GenServer.server(), String.t()) :: :ok | {:error, :not_found}
  def cancel(server \\ __MODULE__, timer_id) when is_binary(timer_id) do
    GenServer.call(server, {:cancel, timer_id})
  end

  @doc "Lists active scheduled timers."
  @spec list(GenServer.server()) :: [map()]
  def list(server \\ __MODULE__) do
    GenServer.call(server, :list)
  end

  @impl true
  def init(opts) do
    registry = Keyword.get(opts, :registry, Pincer.Core.Session.Registry)
    {:ok, %__MODULE__{registry: registry}}
  end

  @impl true
  def handle_call({:schedule, session_id, prompt, delay_ms}, _from, state) do
    id = "timer_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
    ref = Process.send_after(self(), {:fire, id}, delay_ms)

    entry = %{
      id: id,
      ref: ref,
      session_id: session_id,
      prompt: prompt,
      fire_at_ms: System.monotonic_time(:millisecond) + delay_ms
    }

    {:reply, {:ok, id}, %{state | timers: Map.put(state.timers, id, entry)}}
  end

  def handle_call({:cancel, timer_id}, _from, state) do
    case Map.pop(state.timers, timer_id) do
      {nil, _timers} ->
        {:reply, {:error, :not_found}, state}

      {%{ref: ref}, timers} ->
        Process.cancel_timer(ref)
        {:reply, :ok, %{state | timers: timers}}
    end
  end

  def handle_call(:list, _from, state) do
    entries =
      Enum.map(state.timers, fn {_id, timer} ->
        Map.take(timer, [:id, :session_id, :prompt, :fire_at_ms])
      end)

    {:reply, entries, state}
  end

  @impl true
  def handle_info({:fire, id}, state) do
    case Map.pop(state.timers, id) do
      {nil, _timers} ->
        {:noreply, state}

      {%{session_id: session_id, prompt: prompt}, timers} ->
        dispatch_trigger(state.registry, session_id, prompt)
        {:noreply, %{state | timers: timers}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp dispatch_trigger(registry, session_id, prompt) do
    case Registry.lookup(registry, session_id) do
      [{pid, _} | _] -> send(pid, {:cron_trigger, prompt})
      [] -> :ok
    end
  end
end
