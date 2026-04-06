defmodule Pincer.Core.CircuitBreaker do
  @moduledoc """
  Circuit breaker per LLM provider / external service.

  States:
  - `:closed` — normal operation, requests pass through
  - `:open` — circuit tripped, requests fail immediately
  - `:half_open` — testing recovery, one probe request allowed

  Configuration (per provider, in config.yaml or Application env):
  - failure_threshold: number of consecutive failures before opening (default: 5)
  - recovery_timeout_ms: time in open state before trying half_open (default: 30_000)
  - probe_timeout_ms: how long half_open waits for probe result (default: 10_000)

  Usage:
      CircuitBreaker.call("openrouter", fn -> LLM.Client.chat_completion(msgs, opts) end)
  """
  use GenServer

  require Logger

  alias Pincer.Utils.ETSHelper

  @table :pincer_circuit_breaker
  @default_failure_threshold 5
  @default_recovery_timeout 30_000

  defstruct [
    :name,
    state: :closed,
    failure_count: 0,
    last_failure_at: nil,
    success_count: 0
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    ETSHelper.ensure_named_table(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @doc """
  Execute `fun` if the circuit is closed or half-open.
  Records success/failure and transitions state accordingly.
  """
  @spec call(String.t(), (-> any()), keyword()) :: any()
  def call(name, fun, opts \\ []) do
    case state(name) do
      :open ->
        maybe_try_half_open(name, fun, opts)

      state when state in [:closed, :half_open] ->
        try do
          result = fun.()
          on_success(name)
          result
        rescue
          e ->
            on_failure(name, e)
            reraise e, __STACKTRACE__
        end
    end
  end

  @doc "Returns the current state of the circuit for a given name."
  @spec state(String.t()) :: :closed | :open | :half_open
  def state(name) do
    case :ets.lookup(@table, name) do
      [{^name, %__MODULE__{state: state, last_failure_at: last_at}}] ->
        recovery_timeout =
          Application.get_env(:pincer, :circuit_breaker_recovery_ms, @default_recovery_timeout)

        if state == :open and last_at != nil do
          elapsed = System.monotonic_time(:millisecond) - last_at

          if elapsed >= recovery_timeout do
            set_state(name, :half_open)
            :half_open
          else
            :open
          end
        else
          state
        end

      [] ->
        :closed
    end
  end

  @doc "Manually reset a circuit to closed state (admin action)."
  def reset(name) do
    :ets.delete(@table, name)
    Logger.info("CircuitBreaker: #{name} manually reset to closed")
  end

  @doc "Returns a summary of all circuit states."
  def summary do
    :ets.tab2list(@table)
    |> Enum.map(fn {name, cb} -> {name, cb.state, cb.failure_count} end)
  end

  # --- Private ---

  defp on_success(name) do
    cb = get_or_init(name)
    updated = %{cb | state: :closed, failure_count: 0, success_count: cb.success_count + 1}
    :ets.insert(@table, {name, updated})
  end

  defp on_failure(name, reason) do
    cb = get_or_init(name)

    threshold =
      Application.get_env(:pincer, :circuit_breaker_threshold, @default_failure_threshold)

    new_count = cb.failure_count + 1

    updated =
      if new_count >= threshold do
        Logger.warning(
          "CircuitBreaker: #{name} OPENED after #{new_count} failures. Reason: #{inspect(reason)}"
        )

        %{
          cb
          | state: :open,
            failure_count: new_count,
            last_failure_at: System.monotonic_time(:millisecond)
        }
      else
        %{cb | failure_count: new_count, last_failure_at: System.monotonic_time(:millisecond)}
      end

    :ets.insert(@table, {name, updated})
  end

  defp maybe_try_half_open(name, fun, opts) do
    case state(name) do
      :half_open ->
        call(name, fun, opts)

      :open ->
        {:error, {:circuit_open, name}}
    end
  end

  defp set_state(name, new_state) do
    cb = get_or_init(name)
    :ets.insert(@table, {name, %{cb | state: new_state}})
  end

  defp get_or_init(name) do
    case :ets.lookup(@table, name) do
      [{^name, cb}] -> cb
      [] -> %__MODULE__{name: name}
    end
  end
end
