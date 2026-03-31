defmodule Pincer.Core.RateLimiter do
  @moduledoc """
  Per-channel sliding-window rate limiter backed by ETS.

  Default limits (configurable via config.yaml under `rate_limits`):
  - telegram: 30 requests / 60 seconds
  - discord:  20 requests / 60 seconds
  - slack:    20 requests / 60 seconds
  - whatsapp: 10 requests / 60 seconds
  - default:  60 requests / 60 seconds

  Usage:
      case RateLimiter.check(:telegram, "user_123") do
        :ok -> # proceed
        {:error, :rate_limited, retry_after_ms} -> # throttle
      end
  """
  use GenServer

  require Logger

  alias Pincer.Utils.ETSHelper

  @default_limits %{
    telegram: {30, 60_000},
    discord: {20, 60_000},
    slack: {20, 60_000},
    whatsapp: {10, 60_000},
    webhook: {60, 60_000},
    cli: {120, 60_000},
    default: {60, 60_000}
  }

  @table :pincer_rate_limiter

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    ETSHelper.ensure_named_table(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @doc "Check and record a request. Returns :ok or {:error, :rate_limited, retry_after_ms}."
  @spec check(atom() | String.t(), String.t()) :: :ok | {:error, :rate_limited, non_neg_integer()}
  def check(channel_type, key) do
    {limit, window_ms} = limit_for(channel_type)
    now = System.monotonic_time(:millisecond)
    ets_key = {channel_type, key}

    timestamps =
      case :ets.lookup(@table, ets_key) do
        [{^ets_key, ts}] -> ts
        [] -> []
      end

    cutoff = now - window_ms
    recent = Enum.filter(timestamps, &(&1 > cutoff))

    if length(recent) >= limit do
      oldest = Enum.min(recent)
      retry_after = window_ms - (now - oldest)
      {:error, :rate_limited, max(retry_after, 0)}
    else
      :ets.insert(@table, {ets_key, [now | recent]})
      :ok
    end
  end

  defp limit_for(channel_type) when is_atom(channel_type) do
    custom = Application.get_env(:pincer, :rate_limits, %{})
    Map.get(custom, channel_type) || Map.get(@default_limits, channel_type) || @default_limits.default
  end

  defp limit_for(channel_type) when is_binary(channel_type) do
    limit_for(String.to_existing_atom(channel_type))
  rescue
    ArgumentError -> @default_limits.default
  end
end
