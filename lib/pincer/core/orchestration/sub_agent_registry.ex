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
  `:infinity` means uncapped.

  Nested dispatches pass the tree's root session id as `parent_session_id`, so
  the per-session cap is shared by the whole tree. The registry also keeps one
  tree record per root session with the tree's start time and accumulated token
  usage. `reserve/2` enforces `:max_subagent_tree_tokens` (default 200_000) and
  `:max_subagent_tree_ms` (default 1_800_000) against that record; a cap of
  `:infinity` or `0` disables it. Running agents are never interrupted when a
  tree budget is exhausted — only new reservations are rejected. The tree
  record is deleted when its last entry leaves, so a later dispatch starts a
  fresh tree.
  """

  use GenServer

  @default_global_cap 32
  @default_session_cap 8
  @default_tree_token_cap 200_000
  @default_tree_ms_cap 1_800_000

  @type id :: String.t()

  @doc "Starts the registry (registered as `__MODULE__`)."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Reserves a slot for `id` under `parent_session_id` (the tree's root session).

  Returns `:ok` when the id is new or already reserved. Rejections are
  `{:error, :global_limit}`, `{:error, :session_limit}`,
  `{:error, :tree_token_budget}`, or `{:error, :tree_deadline}`. Tree budgets
  are checked against the root's tree record and never interrupt running
  agents.
  """
  @spec reserve(id(), String.t() | nil) ::
          :ok
          | {:error, :global_limit | :session_limit | :tree_token_budget | :tree_deadline}
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

  @doc """
  Adds `tokens` to the tree record for `root_session_id`.

  Invalid token counts and unknown (or already removed) trees are ignored.
  """
  @spec add_usage(id() | nil, integer()) :: :ok
  def add_usage(root_session_id, tokens)
      when (is_binary(root_session_id) or is_nil(root_session_id)) and is_integer(tokens) and
             tokens >= 0 do
    GenServer.call(__MODULE__, {:add_usage, root_session_id, tokens})
  end

  def add_usage(_root_session_id, _tokens), do: :ok

  @doc """
  Returns the tree record's accumulated `tokens` and `age_ms`.

  Returns `:error` when no tree record exists for `root_session_id`.
  """
  @spec tree_usage(id() | nil) ::
          {:ok, %{tokens: non_neg_integer(), age_ms: non_neg_integer()}} | :error
  def tree_usage(root_session_id)
      when is_binary(root_session_id) or is_nil(root_session_id) do
    GenServer.call(__MODULE__, {:tree_usage, root_session_id})
  end

  @doc false
  @impl true
  def init(opts) do
    now_fun = Keyword.get(opts, :now_fun, fn -> System.monotonic_time(:millisecond) end)
    {:ok, %{entries: %{}, trees: %{}, now_fun: now_fun}}
  end

  @doc false
  @impl true
  def handle_call({:reserve, id, parent_session_id}, _from, state) do
    if Map.has_key?(state.entries, id) do
      {:reply, :ok, state}
    else
      root_session_id = parent_session_id
      now = clock_now(state)
      tree = Map.get(state.trees, root_session_id)
      started_at_ms = if tree, do: tree.started_at_ms, else: now
      tokens = if tree, do: tree.tokens, else: 0
      token_cap = tree_cap(:max_subagent_tree_tokens, @default_tree_token_cap)
      ms_cap = tree_cap(:max_subagent_tree_ms, @default_tree_ms_cap)

      cond do
        at_cap?(cap(:max_subagents, @default_global_cap), map_size(state.entries)) ->
          {:reply, {:error, :global_limit}, state}

        at_cap?(
          cap(:max_subagents_per_session, @default_session_cap),
          session_count(state, parent_session_id)
        ) ->
          {:reply, {:error, :session_limit}, state}

        token_cap != :disabled and tokens >= token_cap ->
          {:reply, {:error, :tree_token_budget}, state}

        ms_cap != :disabled and now - started_at_ms >= ms_cap ->
          {:reply, {:error, :tree_deadline}, state}

        true ->
          trees =
            if tree do
              state.trees
            else
              Map.put(state.trees, root_session_id, %{started_at_ms: now, tokens: 0})
            end

          entry = %{
            parent_session_id: parent_session_id,
            root_session_id: root_session_id,
            pid: nil,
            ref: nil
          }

          {:reply, :ok, %{state | entries: Map.put(state.entries, id, entry), trees: trees}}
      end
    end
  end

  def handle_call({:track, id, pid}, _from, state) do
    entry =
      state.entries
      |> Map.get(id, %{
        parent_session_id: nil,
        root_session_id: nil,
        pid: nil,
        ref: nil
      })

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

  def handle_call({:add_usage, root_session_id, tokens}, _from, state) do
    case Map.fetch(state.trees, root_session_id) do
      {:ok, tree} ->
        tree = %{tree | tokens: tree.tokens + tokens}
        {:reply, :ok, %{state | trees: Map.put(state.trees, root_session_id, tree)}}

      :error ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:tree_usage, root_session_id}, _from, state) do
    case Map.fetch(state.trees, root_session_id) do
      {:ok, tree} ->
        age_ms = max(clock_now(state) - tree.started_at_ms, 0)
        {:reply, {:ok, %{tokens: tree.tokens, age_ms: age_ms}}, state}

      :error ->
        {:reply, :error, state}
    end
  end

  @doc false
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {removed, remaining} =
      Enum.split_with(state.entries, fn {_id, entry} -> entry.ref == ref end)

    state = %{state | entries: Map.new(remaining)}

    state =
      Enum.reduce(removed, state, fn {_id, entry}, acc ->
        delete_tree_if_unused(acc, Map.get(entry, :root_session_id))
      end)

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp delete_entry(state, id) do
    case Map.pop(state.entries, id) do
      {nil, _entries} ->
        state

      {%{ref: ref} = entry, entries} ->
        if is_reference(ref), do: Process.demonitor(ref, [:flush])
        delete_tree_if_unused(%{state | entries: entries}, Map.get(entry, :root_session_id))
    end
  end

  defp delete_tree_if_unused(state, root_session_id) do
    if Map.has_key?(state.trees, root_session_id) and not root_in_use?(state, root_session_id) do
      %{state | trees: Map.delete(state.trees, root_session_id)}
    else
      state
    end
  end

  defp root_in_use?(state, root_session_id) do
    Enum.any?(state.entries, fn {_id, entry} ->
      Map.get(entry, :root_session_id) == root_session_id
    end)
  end

  defp clock_now(state) when is_function(state.now_fun, 0), do: state.now_fun.()
  defp clock_now(_state), do: System.monotonic_time(:millisecond)

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

  defp tree_cap(key, default) do
    case Application.get_env(:pincer, key, default) do
      :infinity -> :disabled
      0 -> :disabled
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end
end
