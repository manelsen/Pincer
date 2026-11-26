defmodule Pincer.Core.Pairing.Notifier do
  @moduledoc """
  Formats and broadcasts pairing and invite code announcements to CLI admin
  subscribers via `Pincer.Infra.PubSub` and warning logs.
  """

  require Logger

  alias Pincer.Core.Pairing.Code
  alias Pincer.Infra.PubSub
  alias Pincer.Utils.Time

  @admin_topic "session:cli:admin"

  @doc """
  Builds the structured payload for a sender pairing code announcement.
  """
  @spec build_pairing_payload(term(), term(), String.t(), integer(), keyword()) :: map()
  def build_pairing_payload(channel, sender_id, code, expires_at_ms, opts \\ []) do
    reused? = Keyword.get(opts, :reused, false)
    issued_at_ms = Keyword.get(opts, :issued_at_ms, Time.monotonic_ms())
    ttl_ms = max(expires_at_ms - issued_at_ms, 0)

    %{
      channel: Code.normalize_channel(channel),
      sender_id: Code.normalize_sender(sender_id),
      code: code,
      expires_at_ms: expires_at_ms,
      expires_at_iso: format_timestamp_ms(expires_at_ms),
      ttl_seconds: div(ttl_ms, 1000),
      command: "/pair #{code}",
      reused: reused?
    }
  end

  @doc """
  Builds the structured payload for an out-of-band invite code announcement.
  """
  @spec build_invite_payload(term(), String.t(), integer(), keyword()) :: map()
  def build_invite_payload(channel, code, expires_at_ms, opts \\ []) do
    issued_at_ms = Keyword.get(opts, :issued_at_ms, Time.monotonic_ms())
    ttl_ms = max(expires_at_ms - issued_at_ms, 0)

    %{
      channel: Code.normalize_channel(channel),
      target_agent_id: Code.normalize_stored_agent_id(Keyword.get(opts, :agent_id)),
      code: code,
      expires_at_ms: expires_at_ms,
      expires_at_iso: format_timestamp_ms(expires_at_ms),
      ttl_seconds: div(ttl_ms, 1000),
      command: "/pair #{code}",
      kind: :invite
    }
  end

  @doc """
  Logs and broadcasts a pairing code announcement.
  """
  @spec announce_pairing_code(term(), term(), String.t(), integer(), keyword()) :: :ok
  def announce_pairing_code(channel, sender_id, code, expires_at_ms, opts \\ []) do
    payload = build_pairing_payload(channel, sender_id, code, expires_at_ms, opts)
    action = if payload.reused, do: "reused", else: "issued"

    Logger.warning(
      "[PAIRING] #{action} channel=#{payload.channel} sender=#{payload.sender_id} code=#{payload.code} expires_at=#{payload.expires_at_iso} ttl_s=#{payload.ttl_seconds} command=#{payload.command}"
    )

    safe_broadcast_pairing_code(payload)
  end

  @doc """
  Logs and broadcasts an invite code announcement.
  """
  @spec announce_invite_code(term(), String.t(), integer(), keyword()) :: :ok
  def announce_invite_code(channel, code, expires_at_ms, opts \\ []) do
    payload = build_invite_payload(channel, code, expires_at_ms, opts)

    target_text =
      if is_binary(payload.target_agent_id), do: payload.target_agent_id, else: "<generic>"

    Logger.warning(
      "[PAIRING] issued invite channel=#{payload.channel} target=#{target_text} code=#{payload.code} expires_at=#{payload.expires_at_iso} ttl_s=#{payload.ttl_seconds} command=#{payload.command}"
    )

    safe_broadcast_pairing_code(payload)
  end

  @doc """
  Formats a millisecond unix timestamp as ISO-8601 when valid.
  """
  @spec format_timestamp_ms(term()) :: String.t()
  def format_timestamp_ms(ms) when is_integer(ms) do
    case DateTime.from_unix(ms, :millisecond) do
      {:ok, datetime} -> DateTime.to_iso8601(datetime)
      _ -> Integer.to_string(ms)
    end
  end

  def format_timestamp_ms(ms), do: to_string(ms)

  defp safe_broadcast_pairing_code(payload) when is_map(payload) do
    _ = PubSub.broadcast(@admin_topic, {:pairing_code, payload})
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
