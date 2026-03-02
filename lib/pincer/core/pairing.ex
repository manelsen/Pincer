defmodule Pincer.Core.Pairing do
  @moduledoc """
  Pairing workflow for DM authorization.

  The workflow is intentionally simple and deterministic:
  - issue one-time pairing code with replay window (TTL)
  - approve or reject pending request by code
  - enforce anti-replay by consuming/removing pending codes
  """
  require Logger

  alias Pincer.PubSub

  @table_pending :pincer_pairing_pending
  @table_pairs :pincer_pairing_pairs
  @store_table :pincer_pairing_store
  @store_lock_key {:pincer, :pairing_store_lock}

  @default_ttl_ms 300_000
  @default_max_attempts 5
  @default_code_length 6
  @default_store_path "sessions/pairing_store.dets"

  @type channel :: :telegram | :discord
  @type sender_id :: String.t() | integer()

  @type issue_result :: {:ok, %{code: String.t(), expires_at_ms: non_neg_integer()}}
  @type approve_result ::
          :ok | {:error, :not_pending | :expired | :invalid_code | :attempts_exceeded}
  @type reject_result :: :ok | {:error, :not_pending | :expired | :invalid_code}

  @doc """
  Issues a pairing code for a sender and channel.

  If a pending non-expired code already exists, it is reused to avoid churn.
  """
  @spec issue_code(channel(), sender_id(), keyword()) :: issue_result()
  def issue_code(channel, sender_id, opts \\ []) do
    ensure_tables()
    key = key(channel, sender_id)
    now = now_ms(opts)

    case pending_entry(key) do
      {:ok, pending} ->
        if expired?(pending, now) do
          delete_pending(key)
          create_pending(channel, sender_id, key, now, opts)
        else
          announce_pairing_code(channel, sender_id, pending.code, pending.expires_at_ms,
            reused: true
          )

          {:ok, %{code: pending.code, expires_at_ms: pending.expires_at_ms}}
        end

      :error ->
        create_pending(channel, sender_id, key, now, opts)
    end
  end

  @doc """
  Approves a pending pairing request by code.

  Returns:
  - `:ok` when approved and promoted to paired
  - `{:error, :not_pending | :expired | :invalid_code | :attempts_exceeded}` otherwise
  """
  @spec approve_code(channel(), sender_id(), String.t(), keyword()) :: approve_result()
  def approve_code(channel, sender_id, code, opts \\ []) do
    ensure_tables()
    key = key(channel, sender_id)
    now = now_ms(opts)

    case pending_entry(key) do
      :error ->
        {:error, :not_pending}

      {:ok, pending} ->
        cond do
          expired?(pending, now) ->
            delete_pending(key)
            {:error, :expired}

          attempts_exceeded?(pending) ->
            delete_pending(key)
            {:error, :attempts_exceeded}

          code_valid?(pending, code) ->
            delete_pending(key)
            put_pair(key, %{paired_at_ms: now})
            :ok

          true ->
            next_attempts = pending.attempts + 1
            max_attempts = pending.max_attempts

            if next_attempts >= max_attempts do
              delete_pending(key)
              {:error, :attempts_exceeded}
            else
              updated = %{pending | attempts: next_attempts}
              put_pending(key, updated)
              {:error, :invalid_code}
            end
        end
    end
  end

  @doc """
  Rejects a pending pairing request by code.
  """
  @spec reject_code(channel(), sender_id(), String.t(), keyword()) :: reject_result()
  def reject_code(channel, sender_id, code, opts \\ []) do
    ensure_tables()
    key = key(channel, sender_id)
    now = now_ms(opts)

    case pending_entry(key) do
      :error ->
        {:error, :not_pending}

      {:ok, pending} ->
        cond do
          expired?(pending, now) ->
            delete_pending(key)
            {:error, :expired}

          code_valid?(pending, code) ->
            delete_pending(key)
            :ok

          true ->
            {:error, :invalid_code}
        end
    end
  end

  @doc """
  Returns whether sender is already paired for a channel.
  """
  @spec paired?(channel(), sender_id()) :: boolean()
  def paired?(channel, sender_id) do
    ensure_tables()
    key = key(channel, sender_id)
    match?([{^key, _}], :ets.lookup(@table_pairs, key))
  end

  @doc """
  Clears all pairing tables (test helper).
  """
  @spec reset() :: :ok
  def reset do
    ensure_tables()
    :ets.delete_all_objects(@table_pending)
    :ets.delete_all_objects(@table_pairs)
    clear_persistent_store()
    :ok
  end

  defp create_pending(channel, sender_id, key, now, opts) do
    code = generate_code(opts)
    ttl_ms = ttl_ms(opts)
    max_attempts = max_attempts(opts)
    expires_at_ms = now + ttl_ms

    pending = %{
      code: code,
      code_hash: hash_code(code),
      issued_at_ms: now,
      expires_at_ms: expires_at_ms,
      attempts: 0,
      max_attempts: max_attempts
    }

    put_pending(key, pending)
    announce_pairing_code(channel, sender_id, code, expires_at_ms)
    {:ok, %{code: code, expires_at_ms: expires_at_ms}}
  end

  defp pending_entry(key) do
    case :ets.lookup(@table_pending, key) do
      [{^key, pending}] when is_map(pending) -> {:ok, pending}
      _ -> :error
    end
  end

  defp attempts_exceeded?(pending) do
    pending.attempts >= pending.max_attempts
  end

  defp code_valid?(pending, code) do
    hash_code(code) == pending.code_hash
  end

  defp expired?(pending, now_ms) do
    pending.expires_at_ms <= now_ms
  end

  defp key(channel, sender_id) do
    {
      normalize_channel(channel),
      normalize_sender(sender_id)
    }
  end

  defp normalize_channel(channel) do
    channel
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_sender(sender_id) do
    sender_id
    |> to_string()
    |> String.trim()
  end

  defp hash_code(code) do
    code
    |> to_string()
    |> String.trim()
    |> then(&:crypto.hash(:sha256, &1))
  end

  defp ttl_ms(opts) do
    case Keyword.get(opts, :ttl_ms, @default_ttl_ms) do
      value when is_integer(value) and value > 0 -> value
      _ -> @default_ttl_ms
    end
  end

  defp max_attempts(opts) do
    case Keyword.get(opts, :max_attempts, @default_max_attempts) do
      value when is_integer(value) and value > 0 -> value
      _ -> @default_max_attempts
    end
  end

  defp now_ms(opts) do
    case Keyword.get(opts, :now_ms) do
      value when is_integer(value) -> value
      _ -> System.system_time(:millisecond)
    end
  end

  defp generate_code(opts) do
    generator = Keyword.get(opts, :code_generator, &default_code/0)

    case generator.() do
      value when is_binary(value) and value != "" ->
        value

      value when is_integer(value) ->
        Integer.to_string(value)

      _ ->
        default_code()
    end
  end

  defp default_code do
    1..@default_code_length
    |> Enum.map(fn _ -> Integer.to_string(:rand.uniform(10) - 1) end)
    |> Enum.join()
  end

  defp ensure_tables do
    pending_status = ensure_table(@table_pending)
    pairs_status = ensure_table(@table_pairs)

    if persist_enabled?() and (pending_status == :created or pairs_status == :created) do
      bootstrap_from_store()
    end

    :ok
  end

  defp ensure_table(table) do
    case :ets.whereis(table) do
      :undefined ->
        try do
          :ets.new(table, [:named_table, :set, :public, read_concurrency: true])
          :created
        rescue
          ArgumentError -> :existing
        end

      _tid ->
        :existing
    end
  end

  defp bootstrap_from_store do
    _ =
      with_store(fn store ->
        :dets.foldl(
          fn
            {{:pending, key}, pending}, _acc when is_tuple(key) and is_map(pending) ->
              :ets.insert(@table_pending, {key, pending})
              :ok

            {{:paired, key}, pair_data}, _acc when is_tuple(key) and is_map(pair_data) ->
              :ets.insert(@table_pairs, {key, pair_data})
              :ok

            _entry, _acc ->
              :ok
          end,
          :ok,
          store
        )
      end)

    :ok
  end

  defp put_pending(key, pending) do
    :ets.insert(@table_pending, {key, pending})
    persist_put(:pending, key, pending)
    :ok
  end

  defp put_pair(key, pair_data) do
    :ets.insert(@table_pairs, {key, pair_data})
    persist_put(:paired, key, pair_data)
    :ok
  end

  defp delete_pending(key) do
    :ets.delete(@table_pending, key)
    persist_delete(:pending, key)
    :ok
  end

  defp persist_put(kind, key, value) do
    _ =
      with_store(fn store ->
        :dets.insert(store, {{kind, key}, value})
        :ok
      end)

    :ok
  end

  defp persist_delete(kind, key) do
    _ =
      with_store(fn store ->
        :dets.delete(store, {kind, key})
        :ok
      end)

    :ok
  end

  defp clear_persistent_store do
    _ =
      with_store(fn store ->
        :dets.delete_all_objects(store)
        :ok
      end)

    :ok
  end

  defp with_store(fun) when is_function(fun, 1) do
    if persist_enabled?() do
      :global.trans(@store_lock_key, fn ->
        path = store_path()
        ensure_store_directory(path)
        open_opts = [type: :set, file: String.to_charlist(path), auto_save: 1_000]

        case :dets.open_file(@store_table, open_opts) do
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

  defp persist_enabled? do
    case pairing_config() |> read_config_field("persist") do
      nil -> true
      value -> truthy?(value)
    end
  end

  defp store_path do
    configured = pairing_config() |> read_config_field("store_path")

    path =
      cond do
        is_binary(configured) and String.trim(configured) != "" ->
          configured

        true ->
          @default_store_path
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

      {config_key, value} when is_binary(config_key) and config_key == key ->
        value

      {config_key, value} when is_atom(config_key) ->
        if Atom.to_string(config_key) == key, do: value, else: nil

      _ ->
        nil
    end)
  end

  defp read_config_field(_config, _key), do: nil

  defp truthy?(value) when is_boolean(value), do: value
  defp truthy?(value) when is_integer(value), do: value != 0

  defp truthy?(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "0" -> false
      "false" -> false
      "no" -> false
      "off" -> false
      _ -> true
    end
  end

  defp truthy?(_value), do: true

  defp announce_pairing_code(channel, sender_id, code, expires_at_ms, opts \\ []) do
    reused? = Keyword.get(opts, :reused, false)
    normalized_channel = normalize_channel(channel)
    normalized_sender = normalize_sender(sender_id)
    action = if reused?, do: "reused", else: "issued"

    Logger.warning(
      "[PAIRING] #{action} channel=#{normalized_channel} sender=#{normalized_sender} code=#{code} expires_at_ms=#{expires_at_ms}"
    )

    payload = %{
      channel: normalized_channel,
      sender_id: normalized_sender,
      code: code,
      expires_at_ms: expires_at_ms,
      reused: reused?
    }

    safe_broadcast_pairing_code(payload)
    :ok
  end

  defp safe_broadcast_pairing_code(payload) when is_map(payload) do
    PubSub.broadcast("session:cli:admin", {:pairing_code, payload})
  rescue
    _ -> :ok
  end
end
