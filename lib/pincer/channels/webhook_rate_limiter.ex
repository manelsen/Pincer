defmodule Pincer.Channels.Webhook.RateLimiter do
  @moduledoc """
  Fixed-window, per-client-IP ingress rate limiter for the webhook channel.

  The state lives in this process, so limits are per node, not cluster-wide.
  A window starts with the first request from an IP and lasts `window_ms`.
  Rejected requests neither extend the window nor consume additional budget;
  expired windows are pruned on every check.

  `check/2` uses the injected clock (`:now_fun`), while `check/3` accepts an
  explicit timestamp so tests can drive time deterministically.
  """

  use GenServer

  @default_limit 60
  @default_window_ms 60_000

  @type ip :: :inet.ip_address()

  @type state :: %{
          limit: pos_integer(),
          window_ms: pos_integer(),
          now_fun: (-> integer()),
          windows: %{ip() => {integer(), pos_integer()}}
        }

  @doc """
  Starts the limiter.

  Options:

    * `:limit` - maximum requests per window, defaults to `60`; must be positive
    * `:window_ms` - window length in milliseconds, defaults to `60_000`
    * `:now_fun` - clock used by `check/2`, defaults to
      `&System.monotonic_time(:millisecond)/0`
    * `:name` - registered name, defaults to this module; pass `nil` to skip
      registration (useful for isolated tests)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []

    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Checks a request from `ip` using the server's injected clock.
  """
  @spec check(GenServer.server(), ip()) :: :ok | {:error, pos_integer()}
  def check(server, ip), do: check(server, ip, nil)

  @doc """
  Checks a request from `ip` at `now_ms`.

  Returns `:ok` when the request fits in the current window, or
  `{:error, retry_after_seconds}` when the window is exhausted. `retry_after_seconds`
  is the whole number of seconds until the window resets and is always at least 1.
  When `now_ms` is `nil`, the server's injected clock is used.
  """
  @spec check(GenServer.server(), ip(), integer() | nil) :: :ok | {:error, pos_integer()}
  def check(server, ip, now_ms) do
    GenServer.call(server, {:check, ip, now_ms})
  end

  @impl GenServer
  def init(opts) do
    {:ok,
     %{
       limit: positive_integer(Keyword.get(opts, :limit), @default_limit),
       window_ms: positive_integer(Keyword.get(opts, :window_ms), @default_window_ms),
       now_fun: Keyword.get(opts, :now_fun, fn -> System.monotonic_time(:millisecond) end),
       windows: %{}
     }}
  end

  @impl GenServer
  def handle_call({:check, ip, now_ms}, _from, state) do
    now = if is_integer(now_ms), do: now_ms, else: state.now_fun.()
    windows = prune_windows(state.windows, now, state.window_ms)

    {window_start, count} =
      case Map.get(windows, ip) do
        {start, count} when now - start < state.window_ms -> {start, count}
        _expired_or_missing -> {now, 0}
      end

    if count >= state.limit do
      retry_after = max(1, div(window_start + state.window_ms - now + 999, 1_000))
      {:reply, {:error, retry_after}, %{state | windows: windows}}
    else
      windows = Map.put(windows, ip, {window_start, count + 1})
      {:reply, :ok, %{state | windows: windows}}
    end
  end

  defp prune_windows(windows, now, window_ms) do
    :maps.filter(fn _ip, {start, _count} -> now - start < window_ms end, windows)
  end

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default
end
