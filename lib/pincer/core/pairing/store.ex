defmodule Pincer.Core.Pairing.Store do
  @moduledoc """
  Persistent and in-memory storage owner for the pairing subsystem.

  This GenServer owns the `:pincer_pairing_pending`, `:pincer_pairing_invites`,
  and `:pincer_pairing_pairs` ETS tables (protected against process death via
  `Pincer.Utils.ETSTableHeir`) and keeps DETS handles cached per expanded
  `store_path` instead of opening and closing DETS on every read/write.

  If the server is not running (e.g. in `--no-start` tests), operations fall
  back safely to direct ETS access and scoped DETS open/close.
  """

  use GenServer
  require Logger

  alias Pincer.Core.Pairing.Code
  alias Pincer.Ports.Storage
  alias Pincer.Utils.ETSHelper
  alias Pincer.Utils.ETSTableHeir
  alias Pincer.Utils.MapHelpers

  @default_tables %{
    pending: :pincer_pairing_pending,
    invites: :pincer_pairing_invites,
    pairs: :pincer_pairing_pairs
  }

  @store_lock_key {:pincer, :pairing_store_lock}
  @default_store_path "sessions/pairing_store.dets"
  @known_channels [:telegram, :discord, :whatsapp, "telegram", "discord", "whatsapp"]

  @type tables :: %{pending: atom(), invites: atom(), pairs: atom()}

  @doc "Starts the Pairing Store GenServer."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc "Ensures ETS tables exist and are bootstrapped from durable storage and DETS."
  @spec ensure_tables(keyword()) :: :ok
  def ensure_tables(opts \\ []) do
    tables = tables_from_opts(opts)

    if all_tables_exist?(tables) do
      :ok
    else
      dispatch_or_fallback(
        opts,
        {:ensure_tables, opts},
        fn -> fallback_ensure_tables(tables, opts) end
      )
    end
  end

  @doc "Looks up a pending pairing entry by `{channel, sender_id}` key."
  @spec get_pending(term(), keyword()) :: {:ok, map()} | :error
  def get_pending(key, opts \\ []) do
    read_via_ets_or_server(opts, :pending, {:get_pending, key}, fn table ->
      lookup_map(table, key)
    end)
  end

  @doc "Inserts or updates a pending pairing entry in ETS and DETS."
  @spec put_pending(term(), map(), keyword()) :: :ok
  def put_pending(key, pending, opts \\ []) do
    tables = tables_from_opts(opts)

    dispatch_or_fallback(
      opts,
      {:put_pending, key, pending, opts},
      fn ->
        :ok = fallback_ensure_tables(tables, opts)
        :ets.insert(tables.pending, {key, pending})
        fallback_persist_put(:pending, key, pending, opts)
      end
    )
  end

  @doc "Deletes a pending pairing entry from ETS and DETS."
  @spec delete_pending(term(), keyword()) :: :ok
  def delete_pending(key, opts \\ []) do
    tables = tables_from_opts(opts)

    dispatch_or_fallback(
      opts,
      {:delete_pending, key, opts},
      fn ->
        :ok = fallback_ensure_tables(tables, opts)
        :ets.delete(tables.pending, key)
        fallback_persist_delete(:pending, key, opts)
      end
    )
  end

  @doc "Looks up an invite entry by `{channel, code_hash}` key."
  @spec get_invite(term(), keyword()) :: {:ok, map()} | :error
  def get_invite(key, opts \\ []) do
    read_via_ets_or_server(opts, :invites, {:get_invite, key}, fn table ->
      lookup_map(table, key)
    end)
  end

  @doc "Inserts or updates an invite entry in ETS and DETS."
  @spec put_invite(term(), map(), keyword()) :: :ok
  def put_invite(key, invite, opts \\ []) do
    tables = tables_from_opts(opts)

    dispatch_or_fallback(
      opts,
      {:put_invite, key, invite, opts},
      fn ->
        :ok = fallback_ensure_tables(tables, opts)
        :ets.insert(tables.invites, {key, invite})
        fallback_persist_put(:invite, key, invite, opts)
      end
    )
  end

  @doc "Deletes an invite entry from ETS and DETS."
  @spec delete_invite(term(), keyword()) :: :ok
  def delete_invite(key, opts \\ []) do
    tables = tables_from_opts(opts)

    dispatch_or_fallback(
      opts,
      {:delete_invite, key, opts},
      fn ->
        :ok = fallback_ensure_tables(tables, opts)
        :ets.delete(tables.invites, key)
        fallback_persist_delete(:invite, key, opts)
      end
    )
  end

  @doc "Looks up a paired sender entry by `{channel, sender_id}` key."
  @spec get_pair(term(), keyword()) :: {:ok, term()} | :error
  def get_pair(key, opts \\ []) do
    read_via_ets_or_server(opts, :pairs, {:get_pair, key}, fn table ->
      case :ets.lookup(table, key) do
        [{^key, pair_data}] -> {:ok, pair_data}
        _ -> :error
      end
    end)
  end

  @doc "Returns whether `{channel, sender_id}` is paired."
  @spec paired?(term(), keyword()) :: boolean()
  def paired?(key, opts \\ []) do
    read_via_ets_or_server(opts, :pairs, {:paired?, key}, fn table ->
      match?([{^key, _}], :ets.lookup(table, key))
    end)
  end

  @doc "Persists a paired entry to ETS and durable storage."
  @spec put_pair(term(), map(), keyword()) :: :ok
  def put_pair(key, pair_data, opts \\ []) do
    tables = tables_from_opts(opts)

    dispatch_or_fallback(
      opts,
      {:put_pair, key, pair_data, opts},
      fn ->
        :ok = fallback_ensure_tables(tables, opts)
        :ets.insert(tables.pairs, {key, pair_data})
        persist_pair_to_store(key, pair_data)
      end
    )
  end

  @doc "Returns all pair payload rows stored for a normalized channel."
  @spec select_pair_data_for_channel(String.t(), keyword()) :: [term()]
  def select_pair_data_for_channel(channel, opts \\ []) when is_binary(channel) do
    read_via_ets_or_server(opts, :pairs, {:select_pair_data_for_channel, channel}, fn table ->
      :ets.select(table, [{{{channel, :_}, :"$1"}, [], [:"$1"]}])
    end)
  end

  @doc "Clears all runtime ETS tables and persistent DETS entries."
  @spec reset(keyword()) :: :ok
  def reset(opts \\ []) do
    tables = tables_from_opts(opts)

    dispatch_or_fallback(
      opts,
      {:reset, opts},
      fn ->
        Enum.each([tables.pending, tables.invites, tables.pairs], fn table ->
          ETSHelper.ensure_named_table(table)
          clear_table_if_exists(table)
        end)

        fallback_clear_store(opts)
      end
    )
  end

  @doc "Closes a cached DETS handle for `path`, or all open handles when omitted."
  @spec close_store(String.t() | keyword(), keyword()) :: :ok
  def close_store(path_or_opts \\ [], opts \\ [])

  def close_store(opts, []) when is_list(opts) do
    path = Keyword.get(opts, :store_path)

    dispatch_or_fallback(
      opts,
      {:close_store, path},
      fn -> :ok end
    )
  end

  def close_store(path, opts) when is_binary(path) and is_list(opts) do
    dispatch_or_fallback(
      opts,
      {:close_store, path},
      fn -> :ok end
    )
  end

  @doc "Returns cached DETS handle statistics (`open_paths`, `open_count`) for diagnostics."
  @spec stats(keyword()) :: %{open_paths: [String.t()], open_count: non_neg_integer()}
  def stats(opts \\ []) do
    dispatch_or_fallback(
      opts,
      :stats,
      fn -> %{open_paths: [], open_count: 0} end
    )
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    state = %{
      tables: tables_from_opts(opts),
      default_store_path: Keyword.get(opts, :store_path),
      persist: Keyword.get(opts, :persist),
      dets_handles: %{},
      open_count: 0
    }

    next_state = ensure_tables_in_state(state, opts)
    {:ok, next_state}
  end

  @impl true
  def handle_call({:ensure_tables, opts}, _from, state) do
    next_state = ensure_tables_in_state(state, opts)
    {:reply, :ok, next_state}
  end

  def handle_call({:put_pending, key, pending, opts}, _from, state) do
    state = ensure_tables_in_state(state, opts)
    :ets.insert(state.tables.pending, {key, pending})
    {_res, next_state} = cached_persist_put(state, :pending, key, pending, opts)
    {:reply, :ok, next_state}
  end

  def handle_call({:delete_pending, key, opts}, _from, state) do
    state = ensure_tables_in_state(state, opts)
    :ets.delete(state.tables.pending, key)
    {_res, next_state} = cached_persist_delete(state, :pending, key, opts)
    {:reply, :ok, next_state}
  end

  def handle_call({:put_invite, key, invite, opts}, _from, state) do
    state = ensure_tables_in_state(state, opts)
    :ets.insert(state.tables.invites, {key, invite})
    {_res, next_state} = cached_persist_put(state, :invite, key, invite, opts)
    {:reply, :ok, next_state}
  end

  def handle_call({:delete_invite, key, opts}, _from, state) do
    state = ensure_tables_in_state(state, opts)
    :ets.delete(state.tables.invites, key)
    {_res, next_state} = cached_persist_delete(state, :invite, key, opts)
    {:reply, :ok, next_state}
  end

  def handle_call({:put_pair, key, pair_data, opts}, _from, state) do
    state = ensure_tables_in_state(state, opts)
    :ets.insert(state.tables.pairs, {key, pair_data})
    persist_pair_to_store(key, pair_data)
    {:reply, :ok, state}
  end

  def handle_call({:get_pending, key}, _from, state) do
    {:reply, lookup_map(state.tables.pending, key), state}
  end

  def handle_call({:get_invite, key}, _from, state) do
    {:reply, lookup_map(state.tables.invites, key), state}
  end

  def handle_call({:get_pair, key}, _from, state) do
    reply =
      case :ets.lookup(state.tables.pairs, key) do
        [{^key, pair_data}] -> {:ok, pair_data}
        _ -> :error
      end

    {:reply, reply, state}
  end

  def handle_call({:paired?, key}, _from, state) do
    {:reply, match?([{^key, _}], :ets.lookup(state.tables.pairs, key)), state}
  end

  def handle_call({:select_pair_data_for_channel, channel}, _from, state) do
    reply = :ets.select(state.tables.pairs, [{{{channel, :_}, :"$1"}, [], [:"$1"]}])
    {:reply, reply, state}
  end

  def handle_call({:reset, opts}, _from, state) do
    ensure_owned_table(state.tables.pending)
    ensure_owned_table(state.tables.invites)
    ensure_owned_table(state.tables.pairs)
    clear_table_if_exists(state.tables.pending)
    clear_table_if_exists(state.tables.invites)
    clear_table_if_exists(state.tables.pairs)

    {_res, next_state} =
      with_cached_store(state, opts, fn store ->
        :dets.delete_all_objects(store)
        :ok
      end)

    {:reply, :ok, next_state}
  end

  def handle_call({:close_store, nil}, _from, state) do
    Enum.each(state.dets_handles, fn {_path, store} -> safe_close_dets(store) end)
    {:reply, :ok, %{state | dets_handles: %{}}}
  end

  def handle_call({:close_store, path}, _from, state) when is_binary(path) do
    expanded = Path.expand(path)

    {store, remaining} = Map.pop(state.dets_handles, expanded)
    if store, do: safe_close_dets(store)

    {:reply, :ok, %{state | dets_handles: remaining}}
  end

  def handle_call(:stats, _from, state) do
    stats = %{
      open_paths: state.dets_handles |> Map.keys() |> Enum.sort(),
      open_count: state.open_count
    }

    {:reply, stats, state}
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.dets_handles, fn {_path, store} ->
      safe_close_dets(store)
    end)

    :ok
  end

  # --- Private Helpers ---

  defp read_via_ets_or_server(opts, table_key, call_msg, ets_fun) do
    server = Keyword.get(opts, :server, __MODULE__)
    has_custom_tables? = Keyword.has_key?(opts, :tables)

    if server != __MODULE__ and not has_custom_tables? and server_alive?(server) do
      try do
        GenServer.call(server, call_msg)
      catch
        :exit, {:noproc, _} ->
          :ok = ensure_tables(opts)
          ets_fun.(Map.fetch!(tables_from_opts(opts), table_key))
      end
    else
      :ok = ensure_tables(opts)
      ets_fun.(Map.fetch!(tables_from_opts(opts), table_key))
    end
  end

  defp dispatch_or_fallback(opts, message, fallback_fun) do
    server = Keyword.get(opts, :server, __MODULE__)

    if server_alive?(server) do
      try do
        GenServer.call(server, message)
      catch
        :exit, {:noproc, _} -> fallback_fun.()
      end
    else
      fallback_fun.()
    end
  end

  defp server_alive?(pid) when is_pid(pid), do: Process.alive?(pid)
  defp server_alive?(name) when is_atom(name), do: Process.whereis(name) != nil
  defp server_alive?(_), do: false

  defp tables_from_opts(opts) do
    case Keyword.get(opts, :tables) do
      %{pending: p, invites: i, pairs: pr} when is_atom(p) and is_atom(i) and is_atom(pr) ->
        %{pending: p, invites: i, pairs: pr}

      _ ->
        @default_tables
    end
  end

  defp all_tables_exist?(tables) do
    :ets.whereis(tables.pending) != :undefined and
      :ets.whereis(tables.invites) != :undefined and
      :ets.whereis(tables.pairs) != :undefined
  end

  defp lookup_map(table, key) do
    case :ets.lookup(table, key) do
      [{^key, value}] when is_map(value) -> {:ok, value}
      _ -> :error
    end
  end

  defp ensure_tables_in_state(state, opts) do
    pending_status = ensure_owned_table(state.tables.pending)
    invite_status = ensure_owned_table(state.tables.invites)
    pairs_status = ensure_owned_table(state.tables.pairs)

    if persist_enabled?(state, opts) and
         (pending_status == :created or invite_status == :created or pairs_status == :created) do
      bootstrap_from_store_in_state(state, opts)
    else
      state
    end
  end

  defp ensure_owned_table(table) do
    status = ETSHelper.ensure_named_table(table)

    if Process.whereis(ETSTableHeir) != nil do
      _ = ETSTableHeir.ensure_owned(table)
    end

    status
  end

  defp bootstrap_from_store_in_state(state, opts) do
    load_pairs_from_store(state.tables.pairs)

    {_res, next_state} =
      with_cached_store(state, opts, fn store ->
        fold_dets_into_ets(store, state.tables)
      end)

    next_state
  end

  defp fold_dets_into_ets(store, tables) do
    :dets.foldl(
      fn
        {{:pending, key}, pending}, acc ->
          :ets.insert(tables.pending, {key, pending})
          acc

        {{:invite, key}, invite}, acc ->
          :ets.insert(tables.invites, {key, invite})
          acc

        _entry, acc ->
          acc
      end,
      :ok,
      store
    )
  end

  defp cached_persist_put(state, kind, key, value, opts) do
    with_cached_store(state, opts, fn store ->
      :dets.insert(store, {{kind, key}, value})
      :ok
    end)
  end

  defp cached_persist_delete(state, kind, key, opts) do
    with_cached_store(state, opts, fn store ->
      :dets.delete(store, {kind, key})
      :ok
    end)
  end

  defp with_cached_store(state, opts, fun) when is_function(fun, 1) do
    if persist_enabled?(state, opts) do
      path = resolve_store_path(state, opts)

      case ensure_open_dets(state, path) do
        {:ok, store, next_state} ->
          result = fun.(store)
          _ = :dets.sync(store)
          {result, next_state}

        {:error, reason, next_state} ->
          {{:error, reason}, next_state}
      end
    else
      {:ok, state}
    end
  end

  defp ensure_open_dets(state, path) do
    case Map.get(state.dets_handles, path) do
      nil ->
        open_and_cache_dets(state, path)

      store ->
        if dets_alive?(store, path) do
          {:ok, store, state}
        else
          safe_close_dets(store)
          cleaned = %{state | dets_handles: Map.delete(state.dets_handles, path)}
          open_and_cache_dets(cleaned, path)
        end
    end
  end

  defp dets_alive?(store, path) do
    :dets.info(store, :type) != :undefined and File.exists?(path)
  end

  defp open_and_cache_dets(state, path) do
    ensure_store_directory(path)
    dets_name = {:pincer_pairing_store, path}
    open_opts = [type: :set, file: String.to_charlist(path), auto_save: 1_000]

    case :dets.open_file(dets_name, open_opts) do
      {:ok, store} ->
        next_state = %{
          state
          | dets_handles: Map.put(state.dets_handles, path, store),
            open_count: state.open_count + 1
        }

        {:ok, store, next_state}

      {:error, reason} ->
        Logger.error("[PAIRING] Failed to open store #{path}: #{inspect(reason)}")
        {:error, reason, state}
    end
  end

  defp safe_close_dets(store) do
    _ = :dets.sync(store)
    :dets.close(store)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # --- Fallback helpers when Store GenServer is not started (--no-start) ---

  defp fallback_ensure_tables(tables, opts) do
    pending_status = ETSHelper.ensure_named_table(tables.pending)
    invite_status = ETSHelper.ensure_named_table(tables.invites)
    pairs_status = ETSHelper.ensure_named_table(tables.pairs)

    if persist_enabled?(nil, opts) and
         (pending_status == :created or invite_status == :created or pairs_status == :created) do
      load_pairs_from_store(tables.pairs)

      _ =
        with_dets_fallback(opts, fn store ->
          fold_dets_into_ets(store, tables)
        end)
    end

    :ok
  end

  defp fallback_persist_put(kind, key, value, opts) do
    _ =
      with_dets_fallback(opts, fn store ->
        :dets.insert(store, {{kind, key}, value})
        :ok
      end)

    :ok
  end

  defp fallback_persist_delete(kind, key, opts) do
    _ =
      with_dets_fallback(opts, fn store ->
        :dets.delete(store, {kind, key})
        :ok
      end)

    :ok
  end

  defp fallback_clear_store(opts) do
    _ =
      with_dets_fallback(opts, fn store ->
        :dets.delete_all_objects(store)
        :ok
      end)

    :ok
  end

  defp with_dets_fallback(opts, fun) when is_function(fun, 1) do
    if persist_enabled?(nil, opts) do
      :global.trans(@store_lock_key, fn ->
        path = resolve_store_path(nil, opts)
        ensure_store_directory(path)
        dets_name = {:pincer_pairing_store, path}
        open_opts = [type: :set, file: String.to_charlist(path), auto_save: 1_000]

        case :dets.open_file(dets_name, open_opts) do
          {:ok, store} ->
            try do
              fun.(store)
            after
              _ = :dets.sync(store)
              _ = :dets.close(store)
            end

          {:error, reason} ->
            Logger.error("[PAIRING] Failed to open store #{path}: #{inspect(reason)}")
            {:error, reason}
        end
      end)
    else
      :ok
    end
  end

  defp clear_table_if_exists(table) do
    case :ets.whereis(table) do
      :undefined ->
        :ok

      _tid ->
        try do
          :ets.delete_all_objects(table)
        rescue
          ArgumentError -> :ok
        end
    end
  end

  # --- Config & Durable SQLite Pair Storage ---

  defp persist_enabled?(state, opts) do
    opt_persist = Keyword.get(opts, :persist)
    state_persist = if is_map(state), do: state.persist, else: nil

    cond do
      not is_nil(opt_persist) -> MapHelpers.truthy?(opt_persist)
      not is_nil(state_persist) -> MapHelpers.truthy?(state_persist)
      true -> config_persist_enabled?()
    end
  end

  defp config_persist_enabled? do
    case pairing_config() |> read_config_field("persist") do
      nil -> true
      value -> MapHelpers.truthy?(value)
    end
  end

  defp resolve_store_path(state, opts) do
    opt_path = Keyword.get(opts, :store_path)
    state_path = if is_map(state), do: state.default_store_path, else: nil
    configured = pairing_config() |> read_config_field("store_path")

    path =
      cond do
        is_binary(opt_path) and String.trim(opt_path) != "" -> opt_path
        is_binary(state_path) and String.trim(state_path) != "" -> state_path
        is_binary(configured) and String.trim(configured) != "" -> configured
        true -> @default_store_path
      end

    Path.expand(path)
  end

  defp ensure_store_directory(path) do
    path
    |> Path.dirname()
    |> File.mkdir_p!()
  end

  defp pairing_config do
    Application.get_env(:pincer, :pairing, %{})
  end

  defp read_config_field(config, key) when is_map(config) and is_binary(key) do
    Map.get(config, key) ||
      Enum.find_value(config, fn
        {config_key, value} when is_atom(config_key) ->
          if Atom.to_string(config_key) == key, do: value, else: nil

        _ ->
          nil
      end)
  end

  defp read_config_field(config, key) when is_list(config) and is_binary(key) do
    Enum.find_value(config, fn
      {^key, value} ->
        value

      {config_key, value} when is_atom(config_key) ->
        if Atom.to_string(config_key) == key, do: value, else: nil

      _ ->
        nil
    end)
  end

  defp read_config_field(_config, _key), do: nil

  defp persist_pair_to_store({channel, sender_id}, pair_data) do
    channel_str = Code.normalize_channel(channel)
    sender_str = Code.normalize_sender(sender_id)

    agent_id =
      case Map.get(pair_data, :agent_id) || Map.get(pair_data, "agent_id") do
        nil -> nil
        id -> to_string(id)
      end

    raw_data =
      pair_data
      |> Map.drop([
        :agent_id,
        "agent_id",
        :channel,
        "channel",
        :sender_id,
        "sender_id",
        :paired_at,
        "paired_at"
      ])
      |> Map.new(fn
        {k, v} when is_atom(k) -> {Atom.to_string(k), v}
        pair -> pair
      end)

    Storage.upsert_pairing_state(channel_str, sender_str, agent_id, raw_data)
    :ok
  rescue
    _ ->
      log_persist_warning(channel, sender_id)
  catch
    :exit, _ ->
      log_persist_warning(channel, sender_id)
  end

  defp log_persist_warning(channel, sender_id) do
    Logger.warning("[PAIRING] Could not persist pair to storage",
      channel: Code.normalize_channel(channel),
      sender_id: Code.normalize_sender(sender_id)
    )

    :ok
  end

  defp load_pairs_from_store(pairs_table) do
    for channel <- @known_channels do
      channel_str = Code.normalize_channel(channel)

      for pair <- Storage.list_pairing_states_by_channel(channel_str) do
        key = {channel_str, pair.sender_id}

        pair_data =
          %{
            agent_id: pair.agent_id,
            paired_at: pair.paired_at
          }
          |> Map.merge(pair.raw_data || %{})

        :ets.insert(pairs_table, {key, pair_data})
      end
    end
  rescue
    _ ->
      Logger.warning(
        "[PAIRING] Could not load pairs from storage — schema may not be initialized yet"
      )

      :ok
  catch
    :exit, _ ->
      Logger.warning("[PAIRING] Could not load pairs from storage — storage server not started")

      :ok
  end
end
