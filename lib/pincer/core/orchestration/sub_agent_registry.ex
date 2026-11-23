defmodule Pincer.Core.Orchestration.SubAgentRegistry do
  @moduledoc """
  Admission control and live tracking for supervised Sub-Agents.

  The registry is the single source of truth for how many Sub-Agents are
  active. `reserve/2` enforces the global (`:max_subagents`) and per-session
  (`:max_subagents_per_session`) caps *before* any child is started under the
  `SubAgentSupervisor`; `track/2` attaches a monitor to the started pid so an
  entry disappears on normal exit, crash, or `release/1`.

  Caps are read from application configuration at reservation time, so tests
  and operators can change them without restarting the registry. A cap of
  `:infinity` means uncapped. Nested dispatches pass the tree's root session id
  as `parent_session_id`, so the per-session cap is shared by the whole tree.
  """

  use GenServer

  @default_global_cap 32
  @default_session_cap 8

  @type id :: String.t()

  @doc "Starts the registry (registered as `__MODULE__`)."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Reserves a slot for `id` under `parent_session_id`.

  Returns `:ok` when the id is new or already reserved, otherwise
  `{:error, :global_limit | :session_limit}`.
  """
  @spec reserve(id(), String.t() | nil) :: :ok | {:error, :global_limit | :session_limit}
  def reserve(id, parent_session_id) when is_binary(id) do
    GenServer.call(__MODULE__, {:reserve, id, parent_session_id})
  end

  @doc "Monitors `pid` and removes the entry when it exits."
  @spec track(id(), pid()) :: :ok
  def track(id, pid) when is_binary(id) and is_pid(pid) do
    GenServer.call(__MODULE__, {:track, id, pid})
  end

  @doc "Releases a reservation. Idempotent."
  @spec release(id()) :: :ok
  def release(id) when is_binary(id) do
    GenServer.call(__MODULE__, {:release, id})
  end

  @doc """
  Returns `{:ok, pid}` for a tracked id, `:reserved` for a slot reserved but
  not yet tracked, or `:error`.
  """
  @spec lookup(id()) :: {:ok, pid()} | :reserved | :error
  def lookup(id) when is_binary(id) do
    GenServer.call(__MODULE__, {:lookup, id})
  end

  @doc "Total number of reserved or tracked Sub-Agents."
  @spec count() :: non_neg_integer()
  def count, do: GenServer.call(__MODULE__, :count)

  @doc "Number of reserved or tracked Sub-Agents under a parent session."
  @spec count_for(String.t() | nil) :: non_neg_integer()
  def count_for(parent_session_id),
    do: GenServer.call(__MODULE__, {:count_for, parent_session_id})

  @doc false
  @impl true
  def init(_opts), do: {:ok, %{entries: %{}}}

  @doc false
  @impl true
  def handle_call({:reserve, id, parent_session_id}, _from, state) do
    if Map.has_key?(state.entries, id) do
      {:reply, :ok, state}
    else
      cond do
        at_cap?(cap(:max_subagents, @default_global_cap), map_size(state.entries)) ->
          {:reply, {:error, :global_limit}, state}

        at_cap?(
          cap(:max_subagents_per_session, @default_session_cap),
          session_count(state, parent_session_id)
        ) ->
          {:reply, {:error, :session_limit}, state}

        true ->
          entry = %{parent_session_id: parent_session_id, pid: nil, ref: nil}
          {:reply, :ok, %{state | entries: Map.put(state.entries, id, entry)}}
      end
    end
  end

  def handle_call({:track, id, pid}, _from, state) do
    entry =
      state.entries
      |> Map.get(id, %{parent_session_id: nil, pid: nil, ref: nil})

    if is_reference(entry.ref), do: Process.demonitor(entry.ref, [:flush])

    ref = Process.monitor(pid)
    entry = %{entry | pid: pid, ref: ref}
    {:reply, :ok, %{state | entries: Map.put(state.entries, id, entry)}}
  end

  def handle_call({:release, id}, _from, state) do
    {:reply, :ok, delete_entry(state, id)}
  end

  def handle_call({:lookup, id}, _from, state) do
    reply =
      case Map.get(state.entries, id) do
        %{pid: pid} when is_pid(pid) -> {:ok, pid}
        nil -> :error
        _reserved -> :reserved
      end

    {:reply, reply, state}
  end

  def handle_call(:count, _from, state), do: {:reply, map_size(state.entries), state}

  def handle_call({:count_for, parent_session_id}, _from, state) do
    {:reply, session_count(state, parent_session_id), state}
  end

  @doc false
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    entries = state.entries |> Enum.reject(fn {_id, entry} -> entry.ref == ref end) |> Map.new()
    {:noreply, %{state | entries: entries}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp delete_entry(state, id) do
    case Map.pop(state.entries, id) do
      {nil, _entries} ->
        state

      {%{ref: ref}, entries} ->
        if is_reference(ref), do: Process.demonitor(ref, [:flush])
        %{state | entries: entries}
    end
  end

  defp session_count(state, parent_session_id) do
    Enum.count(state.entries, fn {_id, entry} -> entry.parent_session_id == parent_session_id end)
  end

  defp at_cap?(:infinity, _count), do: false
  defp at_cap?(nil, _count), do: false
  defp at_cap?(limit, count) when is_integer(limit), do: count >= limit
  defp at_cap?(_other, _count), do: false

  defp cap(key, default) do
    case Application.get_env(:pincer, key, default) do
      :infinity -> :infinity
      value when is_integer(value) and value >= 0 -> value
      _ -> default
    end
  end
end
