defmodule Pincer.Core.RateLimiter do
  @moduledoc """
  Per-channel sliding-window rate limiter backed by ETS.

  Default limits (configurable via config.yaml under `rate_limits`):
  - telegram: 30 requests / 60 seconds
  - discord:  20 requests / 60 seconds
  - slack:    20 requests / 60 seconds
  - whatsapp: 10 requests / 60 seconds
  - default:  60 requests / 60 seconds

  The ETS table is `:protected` and owned by this GenServer (with `ETSTableHeir`
  as heir). All window checks and resets are serialized through the GenServer
  so concurrent callers cannot race past the window limit.

  Usage:
      case RateLimiter.check(:telegram, "user_123") do
        :ok -> # proceed
        {:error, :rate_limited, retry_after_ms} -> # throttle
      end
  """
  use GenServer

  alias Pincer.Utils.ETSHelper
  alias Pincer.Utils.ETSTableHeir

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

  @doc "Starts the RateLimiter GenServer."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @impl true
  def init(_opts) do
    _ =
      ETSHelper.ensure_named_table(@table,
        options: [:named_table, :set, :protected, read_concurrency: true]
      )

    :ok = ETSTableHeir.ensure_owned(@table)
    {:ok, %{}}
  end

  @doc """
  Check and record a request.
  Returns `:ok`, `{:error, :rate_limited, retry_after_ms}`, or
  `{:error, :rate_limiter_unavailable}` if the RateLimiter server is not running.
  """
  @spec check(atom() | String.t(), String.t()) ::
          :ok | {:error, :rate_limited, non_neg_integer()} | {:error, :rate_limiter_unavailable}
  def check(channel_type, key) do
    GenServer.call(__MODULE__, {:check, channel_type, key})
  catch
    :exit, {:noproc, _} -> {:error, :rate_limiter_unavailable}
  end

  @doc "Reset all tracked rate-limit windows."
  @spec reset() :: :ok | {:error, :rate_limiter_unavailable}
  def reset do
    GenServer.call(__MODULE__, :reset_all)
  catch
    :exit, {:noproc, _} -> {:error, :rate_limiter_unavailable}
  end

  @doc "Reset the tracked rate-limit window for a channel type and key."
  @spec reset(atom() | String.t(), String.t()) :: :ok | {:error, :rate_limiter_unavailable}
  def reset(channel_type, key) do
    GenServer.call(__MODULE__, {:reset, channel_type, key})
  catch
    :exit, {:noproc, _} -> {:error, :rate_limiter_unavailable}
  end

  # --- GenServer Callbacks ---

  @impl true
  def handle_call({:check, channel_type, key}, _from, state) do
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

    reply =
      if length(recent) >= limit do
        sync_pruned_timestamps(ets_key, timestamps, recent)
        retry_after = retry_after_ms(recent, now, window_ms)
        {:error, :rate_limited, retry_after}
      else
        :ets.insert(@table, {ets_key, [now | recent]})
        :ok
      end

    {:reply, reply, state}
  end

  def handle_call(:reset_all, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  def handle_call({:reset, channel_type, key}, _from, state) do
    :ets.delete(@table, {channel_type, key})
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(_message, state), do: {:noreply, state}

  # --- Private ---

  defp sync_pruned_timestamps(_ets_key, same, same), do: :ok
  defp sync_pruned_timestamps(ets_key, _old, []), do: :ets.delete(@table, ets_key)
  defp sync_pruned_timestamps(ets_key, _old, recent), do: :ets.insert(@table, {ets_key, recent})

  defp retry_after_ms([], _now, window_ms), do: max(window_ms, 0)

  defp retry_after_ms(recent, now, window_ms) do
    oldest = Enum.min(recent)
    max(window_ms - (now - oldest), 0)
  end

  defp limit_for(channel_type) when is_atom(channel_type) do
    custom = Application.get_env(:pincer, :rate_limits, %{})

    Map.get(custom, channel_type) || Map.get(@default_limits, channel_type) ||
      @default_limits.default
  end

  defp limit_for(channel_type) when is_binary(channel_type) do
    limit_for(String.to_existing_atom(channel_type))
  rescue
    ArgumentError -> @default_limits.default
  end
end
