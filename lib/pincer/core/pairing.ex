defmodule Pincer.Core.Pairing do
  @moduledoc """
  Pairing workflow for DM authorization.

  The workflow is intentionally simple and deterministic:
  - issue one-time pairing code with replay window (TTL)
  - approve or reject pending request by code
  - enforce anti-replay by consuming/removing pending codes
  """

  @table_pending :pincer_pairing_pending
  @table_pairs :pincer_pairing_pairs

  @default_ttl_ms 300_000
  @default_max_attempts 5
  @default_code_length 6

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
          :ets.delete(@table_pending, key)
          create_pending(key, now, opts)
        else
          {:ok, %{code: pending.code, expires_at_ms: pending.expires_at_ms}}
        end

      :error ->
        create_pending(key, now, opts)
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
            :ets.delete(@table_pending, key)
            {:error, :expired}

          attempts_exceeded?(pending) ->
            :ets.delete(@table_pending, key)
            {:error, :attempts_exceeded}

          code_valid?(pending, code) ->
            :ets.delete(@table_pending, key)
            :ets.insert(@table_pairs, {key, %{paired_at_ms: now}})
            :ok

          true ->
            next_attempts = pending.attempts + 1
            max_attempts = pending.max_attempts

            if next_attempts >= max_attempts do
              :ets.delete(@table_pending, key)
              {:error, :attempts_exceeded}
            else
              updated = %{pending | attempts: next_attempts}
              :ets.insert(@table_pending, {key, updated})
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
            :ets.delete(@table_pending, key)
            {:error, :expired}

          code_valid?(pending, code) ->
            :ets.delete(@table_pending, key)
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
    :ok
  end

  defp create_pending(key, now, opts) do
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

    :ets.insert(@table_pending, {key, pending})
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
      _ -> System.monotonic_time(:millisecond)
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
    ensure_table(@table_pending)
    ensure_table(@table_pairs)
    :ok
  end

  defp ensure_table(table) do
    case :ets.whereis(table) do
      :undefined ->
        try do
          :ets.new(table, [:named_table, :set, :public, read_concurrency: true])
          :ok
        rescue
          ArgumentError -> :ok
        end

      _tid ->
        :ok
    end
  end
end
