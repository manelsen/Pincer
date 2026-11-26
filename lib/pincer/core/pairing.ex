defmodule Pincer.Core.Pairing do
  @moduledoc """
  Pairing workflow facade for DM authorization.

  The workflow is intentionally simple and deterministic:
  - issue one-time pairing code with replay window (TTL)
  - issue out-of-band invite codes optionally targeting an explicit agent
  - approve or reject pending request by code
  - enforce anti-replay by consuming/removing pending codes

  Delegates code generation/verification to `Pincer.Core.Pairing.Code`,
  storage/persistence to `Pincer.Core.Pairing.Store`, and notifications to
  `Pincer.Core.Pairing.Notifier`.
  """

  require Logger

  alias Pincer.Core.AgentRegistry
  alias Pincer.Core.Pairing.{Code, Notifier, Store}

  @type channel :: :telegram | :discord | :whatsapp
  @type sender_id :: String.t() | integer()

  @type issue_result :: {:ok, %{code: String.t(), expires_at_ms: non_neg_integer()}}
  @type invite_issue_result ::
          {:ok, %{code: String.t(), expires_at_ms: non_neg_integer(), agent_id: String.t() | nil}}
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
    Store.ensure_tables(opts)
    key = Code.key(channel, sender_id)
    now = Code.now_ms(opts)

    case Store.get_pending(key, opts) do
      {:ok, pending} ->
        if Code.expired?(pending, now) do
          Store.delete_pending(key, opts)
          create_pending(channel, sender_id, key, now, opts)
        else
          Notifier.announce_pairing_code(channel, sender_id, pending.code, pending.expires_at_ms,
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
           Code.normalize_explicit_agent_id(Keyword.get(opts, :agent_id), allow_nil?: true) do
      Store.ensure_tables(opts)
      now = Code.now_ms(opts)
      code = Code.generate_invite_code(opts)
      expires_at_ms = now + Code.ttl_ms(opts)
      invite_key = Code.invite_key(channel, code)

      invite = %{
        code: code,
        code_hash: Code.hash_code(code),
        issued_at_ms: now,
        expires_at_ms: expires_at_ms,
        agent_id: agent_id
      }

      Store.put_invite(invite_key, invite, opts)

      Notifier.announce_invite_code(channel, code, expires_at_ms,
        issued_at_ms: now,
        agent_id: agent_id
      )

      {:ok, %{code: code, expires_at_ms: expires_at_ms, agent_id: agent_id}}
    end
  end

  @doc """
  Persists a direct sender-to-agent binding through the pairing store.
  """
  @spec bind(channel(), sender_id(), String.t(), keyword()) ::
          :ok | {:error, {:invalid_agent_id, String.t()}}
  def bind(channel, sender_id, agent_id, opts \\ []) do
    with {:ok, normalized_agent_id} <-
           Code.normalize_explicit_agent_id(agent_id, allow_nil?: false) do
      Store.ensure_tables(opts)
      key = Code.key(channel, sender_id)
      now = Code.now_ms(opts)
      Store.put_pair(key, build_pair_data(now, opts, normalized_agent_id), opts)
      :ok
    end
  end

  @doc """
  Approves a pending pairing request by code.

  Returns `:ok` when approved and promoted to paired, or
  `{:error, :not_pending | :expired | :invalid_code | :attempts_exceeded}`.
  """
  @spec approve_code(channel(), sender_id(), String.t(), keyword()) :: approve_result()
  def approve_code(channel, sender_id, code, opts \\ []) do
    Store.ensure_tables(opts)
    key = Code.key(channel, sender_id)
    now = Code.now_ms(opts)

    case Store.get_pending(key, opts) do
      :error ->
        redeem_invite_fallback(channel, sender_id, code, now, opts, :not_pending)

      {:ok, pending} ->
        cond do
          Code.expired?(pending, now) ->
            Store.delete_pending(key, opts)
            redeem_invite_fallback(channel, sender_id, code, now, opts, :expired)

          pending.attempts >= pending.max_attempts ->
            Store.delete_pending(key, opts)
            redeem_invite_fallback(channel, sender_id, code, now, opts, :attempts_exceeded)

          Code.verify?(pending.code_hash, code) ->
            Store.delete_pending(key, opts)
            Store.put_pair(key, build_pair_data(now, opts), opts)
            :ok

          true ->
            handle_pending_invite_or_increment(channel, sender_id, key, pending, code, now, opts)
        end
    end
  end

  @doc """
  Rejects a pending pairing request by code.
  """
  @spec reject_code(channel(), sender_id(), String.t(), keyword()) :: reject_result()
  def reject_code(channel, sender_id, code, opts \\ []) do
    Store.ensure_tables(opts)
    key = Code.key(channel, sender_id)
    now = Code.now_ms(opts)

    case Store.get_pending(key, opts) do
      :error ->
        {:error, :not_pending}

      {:ok, pending} ->
        cond do
          Code.expired?(pending, now) ->
            Store.delete_pending(key, opts)
            {:error, :expired}

          Code.verify?(pending.code_hash, code) ->
            Store.delete_pending(key, opts)
            :ok

          true ->
            {:error, :invalid_code}
        end
    end
  end

  @doc "Returns whether sender is already paired for a channel."
  @spec paired?(channel(), sender_id()) :: boolean()
  def paired?(channel, sender_id), do: Store.paired?(Code.key(channel, sender_id))

  @doc "Returns the explicit agent bound to a paired sender, when present."
  @spec bound_agent_id(channel(), sender_id()) :: String.t() | nil
  def bound_agent_id(channel, sender_id) do
    case Store.get_pair(Code.key(channel, sender_id)) do
      {:ok, pair_data} when is_map(pair_data) -> extract_agent_id(pair_data)
      _ -> nil
    end
  end

  @doc "Returns whether a given agent/session id is currently bound by any sender on the channel."
  @spec bound_agent_session?(channel(), String.t()) :: boolean()
  def bound_agent_session?(channel, agent_id) do
    normalized_channel = Code.normalize_channel(channel)

    case Code.normalize_stored_agent_id(agent_id) do
      nil ->
        false

      normalized_agent_id ->
        normalized_channel
        |> Store.select_pair_data_for_channel()
        |> Enum.any?(fn
          pair_data when is_map(pair_data) -> extract_agent_id(pair_data) == normalized_agent_id
          _ -> false
        end)
    end
  end

  @doc "Clears all pairing tables (test helper)."
  @spec reset() :: :ok
  def reset, do: Store.reset()

  # --- Private Workflow Helpers ---

  defp extract_agent_id(pair_data) do
    Code.normalize_stored_agent_id(
      Map.get(pair_data, :agent_id) || Map.get(pair_data, "agent_id")
    )
  end

  defp create_pending(channel, sender_id, key, now, opts) do
    code = Code.generate_code(opts)
    expires_at_ms = now + Code.ttl_ms(opts)

    pending = %{
      code: code,
      code_hash: Code.hash_code(code),
      issued_at_ms: now,
      expires_at_ms: expires_at_ms,
      attempts: 0,
      max_attempts: Code.max_attempts(opts)
    }

    Store.put_pending(key, pending, opts)
    Notifier.announce_pairing_code(channel, sender_id, code, expires_at_ms, issued_at_ms: now)
    {:ok, %{code: code, expires_at_ms: expires_at_ms}}
  end

  defp handle_pending_invite_or_increment(channel, sender_id, key, pending, code, now, opts) do
    case redeem_invite(channel, sender_id, code, now, opts) do
      {:ok, _pair} ->
        Store.delete_pending(key, opts)
        :ok

      {:error, :expired} ->
        {:error, :expired}

      {:error, :not_found} ->
        next_attempts = pending.attempts + 1

        if next_attempts >= pending.max_attempts do
          Store.delete_pending(key, opts)
          {:error, :attempts_exceeded}
        else
          Store.put_pending(key, %{pending | attempts: next_attempts}, opts)
          {:error, :invalid_code}
        end
    end
  end

  defp redeem_invite_fallback(channel, sender_id, code, now, opts, not_found_error) do
    case redeem_invite(channel, sender_id, code, now, opts) do
      {:ok, _pair} -> :ok
      {:error, :expired} -> {:error, :expired}
      {:error, :not_found} -> {:error, not_found_error}
    end
  end

  defp redeem_invite(channel, sender_id, code, now, opts) do
    invite_key = Code.invite_key(channel, code)
    pair_key = Code.key(channel, sender_id)

    case Store.get_invite(invite_key, opts) do
      :error ->
        {:error, :not_found}

      {:ok, invite} ->
        if Code.expired?(invite, now) do
          Store.delete_invite(invite_key, opts)
          {:error, :expired}
        else
          Store.delete_invite(invite_key, opts)
          Store.put_pair(pair_key, build_pair_data(now, opts, invite.agent_id), opts)
          {:ok, %{agent_id: invite.agent_id}}
        end
    end
  end

  defp build_pair_data(now, opts, explicit_agent_id \\ nil) do
    case Code.normalize_stored_agent_id(resolve_agent_id(explicit_agent_id, opts)) do
      nil -> %{paired_at_ms: now}
      agent_id -> %{paired_at_ms: now, agent_id: agent_id}
    end
  end

  defp resolve_agent_id(explicit_agent_id, _opts)
       when is_binary(explicit_agent_id) and explicit_agent_id != "",
       do: explicit_agent_id

  defp resolve_agent_id(_explicit_agent_id, opts) do
    case opts |> Keyword.get(:default_agent_id) |> Code.normalize_stored_agent_id() do
      id when is_binary(id) ->
        id

      nil ->
        opts
        |> Keyword.get(:agent_factory, &AgentRegistry.create_root_agent!/0)
        |> invoke_factory()
    end
  end

  defp invoke_factory(factory) when is_function(factory, 0) do
    case factory.() do
      %{agent_id: agent_id} -> agent_id
      {:ok, %{agent_id: agent_id}} -> agent_id
      {:ok, agent_id} -> agent_id
      agent_id when is_binary(agent_id) -> agent_id
      _ -> nil
    end
  rescue
    error ->
      Logger.error("[PAIRING] Failed to create agent for generic pairing: #{inspect(error)}")
      nil
  end

  defp invoke_factory(_invalid_factory), do: nil
end
