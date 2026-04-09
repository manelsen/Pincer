defmodule Pincer.Core.Pairing do
  @moduledoc """
  Pairing workflow for DM authorization.

  The workflow is intentionally simple and deterministic:
  - issue one-time pairing code with replay window (TTL)
  - issue out-of-band invite codes optionally targeting an explicit agent
  - approve or reject pending request by code
  - enforce anti-replay by consuming/removing pending codes
  """
  require Logger

  alias Pincer.Core.AgentRegistry
  alias Pincer.Infra.PubSub
  alias Pincer.Utils.ETSHelper
  alias Pincer.Utils.MapHelpers
  alias Pincer.Utils.Time

  @table_pending :pincer_pairing_pending
  @table_invites :pincer_pairing_invites
  @table_pairs :pincer_pairing_pairs
  @store_table :pincer_pairing_store
  @store_lock_key {:pincer, :pairing_store_lock}

  @default_ttl_ms 300_000
  @default_max_attempts 5
  @default_code_length 6
  @default_store_path "sessions/pairing_store.dets"

  @type channel :: :telegram | :discord | :whatsapp
  @type sender_id :: String.t() | integer()

  @type issue_result :: {:ok, %{code: String.t(), expires_at_ms: non_neg_integer()}}
  @type invite_issue_result ::
          {:ok,
           %{
             code: String.t(),
             expires_at_ms: non_neg_integer(),
             agent_id: String.t() | nil
           }}
          | {:error, {:invalid_agent_id, String.t()}}
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
            reused: true,
            issued_at_ms: pending.issued_at_ms
          )

          {:ok, %{code: pending.code, expires_at_ms: pending.expires_at_ms}}
        end

      :error ->
        create_pending(channel, sender_id, key, now, opts)
    end
  end

  @doc """
  Issues an out-of-band invite code for a channel.

  The invite may optionally target an explicit `agent_id`. Any sender that
  redeems the code via `/pair <codigo>` can consume it exactly once.
  """
  @spec issue_invite(channel(), keyword()) :: invite_issue_result()
  def issue_invite(channel, opts \\ []) do
    with {:ok, agent_id} <-
           normalize_explicit_agent_id(Keyword.get(opts, :agent_id), allow_nil?: true) do
      ensure_tables()
      now = now_ms(opts)
      code = generate_invite_code(opts)
      expires_at_ms = now + ttl_ms(opts)
      invite_key = invite_key(channel, code)

      invite = %{
        code: code,
        code_hash: hash_code(code),
        issued_at_ms: now,
        expires_at_ms: expires_at_ms,
        agent_id: agent_id
      }

      put_invite(invite_key, invite)
      announce_invite_code(channel, code, expires_at_ms, issued_at_ms: now, agent_id: agent_id)

      {:ok, %{code: code, expires_at_ms: expires_at_ms, agent_id: agent_id}}
    end
  end

  @doc """
  Persists a direct sender-to-agent binding through the pairing store.
  """
  @spec bind(channel(), sender_id(), String.t(), keyword()) ::
          :ok | {:error, {:invalid_agent_id, String.t()}}
  def bind(channel, sender_id, agent_id, opts \\ []) do
    with {:ok, normalized_agent_id} <- normalize_explicit_agent_id(agent_id, allow_nil?: false) do
      ensure_tables()
      key = key(channel, sender_id)
      now = now_ms(opts)
      put_pair(key, build_pair_data(channel, sender_id, now, opts, normalized_agent_id))
      :ok
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
        redeem_invite_fallback(channel, sender_id, code, now, opts, :not_pending)

      {:ok, pending} ->
        cond do
          expired?(pending, now) ->
            delete_pending(key)
            redeem_invite_fallback(channel, sender_id, code, now, opts, :expired)

          attempts_exceeded?(pending) ->
            delete_pending(key)
            redeem_invite_fallback(channel, sender_id, code, now, opts, :attempts_exceeded)

          code_valid?(pending, code) ->
            delete_pending(key)
            put_pair(key, build_pair_data(channel, sender_id, now, opts))
            :ok

          true ->
            case redeem_invite(channel, sender_id, code, now, opts) do
              {:ok, _pair} ->
                delete_pending(key)
                :ok

              {:error, :expired} ->
                {:error, :expired}

              {:error, :not_found} ->
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
  end

  # Attempts an invite-code redeem and maps {:error, :not_found} to the
  # caller-supplied `not_found_error` atom (varies per leg of approve_code/4).
  defp redeem_invite_fallback(channel, sender_id, code, now, opts, not_found_error) do
    case redeem_invite(channel, sender_id, code, now, opts) do
      {:ok, _pair} -> :ok
      {:error, :expired} -> {:error, :expired}
      {:error, :not_found} -> {:error, not_found_error}
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
  Returns the explicit agent bound to a paired sender, when present.
  """
  @spec bound_agent_id(channel(), sender_id()) :: String.t() | nil
  def bound_agent_id(channel, sender_id) do
    ensure_tables()
    key = key(channel, sender_id)

    case :ets.lookup(@table_pairs, key) do
      [{^key, pair_data}] when is_map(pair_data) ->
        normalize_stored_agent_id(Map.get(pair_data, :agent_id) || Map.get(pair_data, "agent_id"))

      _ ->
        nil
    end
  end

  @doc """
  Returns whether a given agent/session id is currently bound by any sender on the channel.
  """
  @spec bound_agent_session?(channel(), String.t()) :: boolean()
  def bound_agent_session?(channel, agent_id) do
    ensure_tables()
    normalized_channel = normalize_channel(channel)
    normalized_agent_id = normalize_stored_agent_id(agent_id)
    do_bound_agent_session?(normalized_channel, normalized_agent_id)
  end

  defp do_bound_agent_session?(_channel, nil), do: false

  defp do_bound_agent_session?(channel, normalized_agent_id) do
    channel
    |> select_pair_data_for_channel()
    |> Enum.any?(fn
      pair_data when is_map(pair_data) ->
        normalize_stored_agent_id(Map.get(pair_data, :agent_id) || Map.get(pair_data, "agent_id")) ==
          normalized_agent_id

      _ ->
        false
    end)
  end

  @doc """
  Clears all pairing tables (test helper).
  """
  @spec reset() :: :ok
  def reset do
    ensure_table(@table_pending)
    ensure_table(@table_invites)
    ensure_table(@table_pairs)
    clear_table_if_exists(@table_pending)
    clear_table_if_exists(@table_invites)
    clear_table_if_exists(@table_pairs)
    clear_persistent_store()
    :ok
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
    announce_pairing_code(channel, sender_id, code, expires_at_ms, issued_at_ms: now)
    {:ok, %{code: code, expires_at_ms: expires_at_ms}}
  end

  defp pending_entry(key) do
    case :ets.lookup(@table_pending, key) do
      [{^key, pending}] when is_map(pending) -> {:ok, pending}
      _ -> :error
    end
  end

  defp invite_entry(key) do
    case :ets.lookup(@table_invites, key) do
      [{^key, invite}] when is_map(invite) -> {:ok, invite}
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

  defp invite_key(channel, code) do
    {
      normalize_channel(channel),
      hash_code(code)
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
    |> normalize_code()
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
      _ -> Time.monotonic_ms()
    end
  end

  defp generate_code(opts) do
    generator = Keyword.get(opts, :code_generator, &default_code/0)

    case generator.() do
      value when is_binary(value) and value != "" ->
        normalize_code(value)

      value when is_integer(value) ->
        value |> Integer.to_string() |> normalize_code()

      _ ->
        default_code()
    end
  end

  defp generate_invite_code(opts) do
    generator = Keyword.get(opts, :code_generator, &default_invite_code/0)

    case generator.() do
      value when is_binary(value) and value != "" ->
        normalize_code(value)

      value when is_integer(value) ->
        value |> Integer.to_string() |> normalize_code()

      _ ->
        default_invite_code()
    end
  end

  defp default_code do
    1..@default_code_length
    |> Enum.map(fn _ -> Integer.to_string(:rand.uniform(10) - 1) end)
    |> Enum.join()
    |> normalize_code()
  end

  defp default_invite_code do
    token =
      5
      |> :crypto.strong_rand_bytes()
      |> Base.encode32(padding: false)
      |> String.slice(0, 8)

    normalize_code("PAIR_#{token}")
  end

  defp select_pair_data_for_channel(channel) when is_binary(channel) do
    :ets.select(@table_pairs, [
      {{{channel, :_}, :"$1"}, [], [:"$1"]}
    ])
  end

  defp ensure_tables do
    pending_status = ensure_table(@table_pending)
    invite_status = ensure_table(@table_invites)
    pairs_status = ensure_table(@table_pairs)

    if persist_enabled?() and
         (pending_status == :created or invite_status == :created or pairs_status == :created) do
      bootstrap_from_store()
    end

    :ok
  end

  defp ensure_table(table) do
    ETSHelper.ensure_named_table(table)
  end

  defp bootstrap_from_store do
    # Pairs are durable — loaded from Postgres into ETS (survives Docker restart)
    load_pairs_from_postgres()

    # Pending/invite are ephemeral — loaded from DETS (they expire anyway)
    _ =
      with_store(fn store ->
        :dets.foldl(
          fn
            {{:pending, key}, pending}, acc ->
              :ets.insert(@table_pending, {key, pending})
              acc

            {{:invite, key}, invite}, acc ->
              :ets.insert(@table_invites, {key, invite})
              acc

            _entry, acc ->
              acc
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
    persist_pair_to_postgres(key, pair_data)
    :ok
  end

  defp put_invite(key, invite) do
    :ets.insert(@table_invites, {key, invite})
    persist_put(:invite, key, invite)
    :ok
  end

  defp delete_pending(key) do
    :ets.delete(@table_pending, key)
    persist_delete(:pending, key)
    :ok
  end

  defp delete_invite(key) do
    :ets.delete(@table_invites, key)
    persist_delete(:invite, key)
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
      value -> MapHelpers.truthy?(value)
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

  defp announce_pairing_code(channel, sender_id, code, expires_at_ms, opts) do
    reused? = Keyword.get(opts, :reused, false)
    issued_at_ms = Keyword.get(opts, :issued_at_ms, Time.monotonic_ms())
    normalized_channel = normalize_channel(channel)
    normalized_sender = normalize_sender(sender_id)
    action = if reused?, do: "reused", else: "issued"
    ttl_ms = max(expires_at_ms - issued_at_ms, 0)
    ttl_seconds = div(ttl_ms, 1000)
    expires_at_iso = format_timestamp_ms(expires_at_ms)
    command = "/pair #{code}"

    Logger.warning(
      "[PAIRING] #{action} channel=#{normalized_channel} sender=#{normalized_sender} code=#{code} expires_at=#{expires_at_iso} ttl_s=#{ttl_seconds} command=#{command}"
    )

    payload = %{
      channel: normalized_channel,
      sender_id: normalized_sender,
      code: code,
      expires_at_ms: expires_at_ms,
      expires_at_iso: expires_at_iso,
      ttl_seconds: ttl_seconds,
      command: command,
      reused: reused?
    }

    safe_broadcast_pairing_code(payload)
    :ok
  end

  defp announce_invite_code(channel, code, expires_at_ms, opts) do
    issued_at_ms = Keyword.get(opts, :issued_at_ms, Time.monotonic_ms())
    normalized_channel = normalize_channel(channel)
    target_agent_id = normalize_stored_agent_id(Keyword.get(opts, :agent_id))
    ttl_ms = max(expires_at_ms - issued_at_ms, 0)
    ttl_seconds = div(ttl_ms, 1000)
    expires_at_iso = format_timestamp_ms(expires_at_ms)
    command = "/pair #{code}"
    target_text = if is_binary(target_agent_id), do: target_agent_id, else: "<generic>"

    Logger.warning(
      "[PAIRING] issued invite channel=#{normalized_channel} target=#{target_text} code=#{code} expires_at=#{expires_at_iso} ttl_s=#{ttl_seconds} command=#{command}"
    )

    payload = %{
      channel: normalized_channel,
      target_agent_id: target_agent_id,
      code: code,
      expires_at_ms: expires_at_ms,
      expires_at_iso: expires_at_iso,
      ttl_seconds: ttl_seconds,
      command: command,
      kind: :invite
    }

    safe_broadcast_pairing_code(payload)
    :ok
  end

  defp format_timestamp_ms(ms) when is_integer(ms) do
    case DateTime.from_unix(ms, :millisecond) do
      {:ok, datetime} -> DateTime.to_iso8601(datetime)
      _ -> Integer.to_string(ms)
    end
  end

  defp format_timestamp_ms(ms), do: to_string(ms)

  defp safe_broadcast_pairing_code(payload) when is_map(payload) do
    PubSub.broadcast("session:cli:admin", {:pairing_code, payload})
  rescue
    _ -> :ok
  end

  defp redeem_invite(channel, sender_id, code, now, opts) do
    invite_key = invite_key(channel, code)
    pair_key = key(channel, sender_id)

    case invite_entry(invite_key) do
      :error ->
        {:error, :not_found}

      {:ok, invite} ->
        if expired?(invite, now) do
          delete_invite(invite_key)
          {:error, :expired}
        else
          delete_invite(invite_key)
          put_pair(pair_key, build_pair_data(channel, sender_id, now, opts, invite.agent_id))
          {:ok, %{agent_id: invite.agent_id}}
        end
    end
  end

  defp build_pair_data(channel, sender_id, now, opts, explicit_agent_id \\ nil) do
    agent_id = resolve_agent_id(channel, sender_id, explicit_agent_id, opts)

    %{paired_at_ms: now}
    |> maybe_put_agent_id(normalize_stored_agent_id(agent_id))
  end

  defp resolve_agent_id(_channel, _sender_id, explicit_agent_id, _opts)
       when is_binary(explicit_agent_id) and explicit_agent_id != "" do
    normalize_stored_agent_id(explicit_agent_id)
  end

  defp resolve_agent_id(_channel, _sender_id, _explicit_agent_id, opts) do
    default_agent_id =
      opts
      |> Keyword.get(:default_agent_id)
      |> normalize_stored_agent_id()

    if is_binary(default_agent_id) do
      default_agent_id
    else
      opts
      |> Keyword.get(:agent_factory, &default_agent_factory/0)
      |> invoke_agent_factory()
    end
  end

  defp invoke_agent_factory(factory) when is_function(factory, 0) do
    case factory.() do
      %{agent_id: agent_id} -> normalize_stored_agent_id(agent_id)
      {:ok, %{agent_id: agent_id}} -> normalize_stored_agent_id(agent_id)
      {:ok, agent_id} -> normalize_stored_agent_id(agent_id)
      agent_id when is_binary(agent_id) -> normalize_stored_agent_id(agent_id)
      _ -> nil
    end
  rescue
    error ->
      Logger.error("[PAIRING] Failed to create agent for generic pairing: #{inspect(error)}")
      nil
  end

  defp invoke_agent_factory(_invalid_factory), do: nil

  defp default_agent_factory do
    AgentRegistry.create_root_agent!()
  end

  defp maybe_put_agent_id(pair_data, nil), do: pair_data
  defp maybe_put_agent_id(pair_data, agent_id), do: Map.put(pair_data, :agent_id, agent_id)

  defp normalize_explicit_agent_id(agent_id, opts) do
    allow_nil? = Keyword.get(opts, :allow_nil?, false)
    candidate = normalize_trimmed_agent_id(agent_id)

    cond do
      is_nil(candidate) and allow_nil? ->
        {:ok, nil}

      is_nil(candidate) ->
        {:error, {:invalid_agent_id, "Invalid agent_id #{inspect(agent_id)}: cannot be empty"}}

      true ->
        try do
          {:ok, AgentRegistry.normalize_agent_id!(candidate)}
        rescue
          error in ArgumentError -> {:error, {:invalid_agent_id, Exception.message(error)}}
        end
    end
  end

  defp normalize_stored_agent_id(agent_id) do
    case normalize_trimmed_agent_id(agent_id) do
      nil ->
        nil

      candidate ->
        try do
          AgentRegistry.normalize_agent_id!(candidate)
        rescue
          ArgumentError -> nil
        end
    end
  end

  defp normalize_trimmed_agent_id(nil), do: nil

  defp normalize_trimmed_agent_id(agent_id) do
    candidate =
      agent_id
      |> to_string()
      |> String.trim()

    if candidate == "", do: nil, else: candidate
  end

  defp normalize_code(code) do
    code
    |> to_string()
    |> String.trim()
    |> String.upcase()
  end

  # --- Postgres-backed durable pair storage ---

  # Persists a pair to Postgres (durable) while ETS holds it for speed.
  # Called after every successful bind/approve so pairs survive restarts.
  defp persist_pair_to_postgres({channel, sender_id}, pair_data) do
    channel_str = normalize_channel(channel)
    sender_str = normalize_sender(sender_id)

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

    Pincer.Ports.Storage.upsert_pairing_state(channel_str, sender_str, agent_id, raw_data)
    :ok
  rescue
    _ ->
      # Fail silently — pairing still works via ETS, just no durability
      Logger.warning("[PAIRING] Could not persist pair to Postgres",
        channel: normalize_channel(channel),
        sender_id: normalize_sender(sender_id)
      )

      :ok
  end

  # Loads all durable pairs from Postgres into ETS on startup.
  # This is called from bootstrap_from_store so existing pairs survive reboots.
  defp load_pairs_from_postgres do
    for channel <- [:telegram, :discord, :whatsapp, "telegram", "discord", "whatsapp"] do
      channel_str = normalize_channel(channel)

      for pair <- Pincer.Ports.Storage.list_pairing_states_by_channel(channel_str) do
        key = {channel_str, pair.sender_id}

        pair_data =
          %{
            agent_id: pair.agent_id,
            paired_at: pair.paired_at
          }
          |> Map.merge(pair.raw_data || %{})

        :ets.insert(@table_pairs, {key, pair_data})
      end
    end
  rescue
    _ ->
      Logger.warning("[PAIRING] Could not load pairs from Postgres — tables may not exist yet")
      :ok
  end
end
