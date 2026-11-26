defmodule Pincer.Test.Support.SyncHelpers do
  @moduledoc """
  Deterministic synchronization, polling, and process lifecycle helpers for tests.
  """

  @default_timeout_ms 1_000
  @default_interval_ms 5

  @doc """
  Polls `fun.()` until it returns a truthy value (and does not raise
  `ExUnit.AssertionError`), or fails after `:timeout` ms.

  Uses `receive after` rather than `Process.sleep/1` and supports both boolean
  predicates and assertion-raising blocks.

  ## Options

    * `:timeout` - Maximum wait time in milliseconds (default `#{@default_timeout_ms}`).
    * `:interval` - Delay between attempts in milliseconds (default `#{@default_interval_ms}`).
    * `:message` - Custom failure message if the condition is not met before timeout.
  """
  @spec eventually((-> term()), keyword()) :: term()
  def eventually(fun, opts \\ []) when is_function(fun, 0) and is_list(opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)
    interval = Keyword.get(opts, :interval, @default_interval_ms)
    message = Keyword.get(opts, :message)
    deadline = System.monotonic_time(:millisecond) + timeout

    do_eventually(fun, deadline, interval, message)
  end

  defp do_eventually(fun, deadline, interval, message) do
    try do
      case fun.() do
        result when result in [false, nil] ->
          retry_or_fail(fun, deadline, interval, message, nil)

        result ->
          result
      end
    rescue
      e in [ExUnit.AssertionError] ->
        retry_or_fail(fun, deadline, interval, message, e)
    end
  end

  defp retry_or_fail(fun, deadline, interval, message, last_error) do
    if System.monotonic_time(:millisecond) < deadline do
      receive do
      after
        interval -> do_eventually(fun, deadline, interval, message)
      end
    else
      cond do
        is_binary(message) ->
          raise ExUnit.AssertionError, message: message

        last_error != nil ->
          reraise last_error, []

        true ->
          raise ExUnit.AssertionError,
            message: "eventually/2 timed out before condition became truthy"
      end
    end
  end

  @doc """
  Drains all currently queued messages from the calling process's mailbox and
  returns them in arrival order.
  """
  @spec flush_mailbox() :: [term()]
  def flush_mailbox do
    do_flush_mailbox([])
  end

  defp do_flush_mailbox(acc) do
    receive do
      msg -> do_flush_mailbox([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  @doc """
  Synchronizes with a GenServer or registered process via `:sys.get_state/1`,
  guaranteeing all previously sent casts and messages have been processed.
  """
  @spec barrier(pid() | atom()) :: term()
  def barrier(server) when is_pid(server) or is_atom(server) do
    :sys.get_state(server)
  end

  @doc """
  Ensures one or more named processes or child specs are running.

  If the target process name is already registered, this is a no-op; otherwise
  it starts the process under ExUnit supervision via `ExUnit.Callbacks.start_supervised!/1`.
  """
  @spec ensure_started!(Supervisor.child_spec() | {module(), term()} | module() | [term()]) ::
          :ok | pid()
  def ensure_started!(specs) when is_list(specs) do
    Enum.each(specs, &ensure_started!/1)
    :ok
  end

  def ensure_started!(spec) do
    case target_name(spec) do
      name when is_atom(name) and name != nil ->
        case Process.whereis(name) do
          nil -> start_if_not_started!(spec)
          pid -> pid
        end

      _ ->
        start_if_not_started!(spec)
    end
  end

  defp start_if_not_started!(spec) do
    case ExUnit.Callbacks.start_supervised(spec) do
      {:ok, pid} ->
        pid

      {:error, {:already_started, pid}} ->
        pid

      {:error, {{:already_started, pid}, _child}} ->
        pid

      {:error, reason} ->
        raise RuntimeError,
              "failed to start child with the spec #{inspect(spec)}. Reason: #{inspect(reason)}"
    end
  end

  @doc """
  Allocates a temporary SQLite database file path under `System.tmp_dir!()` and
  deletes its directory on test exit.
  """
  @spec temp_sqlite_path!(String.t()) :: String.t()
  def temp_sqlite_path!(prefix \\ "pincer_sqlite_test") when is_binary(prefix) do
    dir = Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(dir) end)
    Path.join(dir, "pincer.db")
  end

  defp target_name(mod) when is_atom(mod), do: mod
  defp target_name({Pincer.Infra.PubSub, _}), do: Pincer.Infra.PubSub

  defp target_name({mod, opts}) when is_atom(mod) and is_list(opts) do
    Keyword.get(opts, :name, mod)
  end

  defp target_name(%{start: {_m, _f, _a}} = spec) do
    Map.get(spec, :id)
  end

  defp target_name(_), do: nil
end
