defmodule Pincer.LLM.FailoverDispatch do
  @moduledoc """
  Turns an exhausted request into a failover action: re-enter on another
  provider or model, or stop and return the failure.

  The recovery call is supplied by the caller as `retry.(provider, model, state)`
  so this module never re-enters `Pincer.LLM.Client` directly; telemetry and
  runtime-status reporting arrive as callbacks for the same reason.
  """

  alias Pincer.Core.LLM.CooldownStore
  alias Pincer.Core.LLM.FailoverPolicy
  alias Pincer.Core.Policy
  alias Pincer.LLM.CooldownRouting

  @type action :: :chat_completion | :stream_completion
  @type retry_fun :: (String.t(), String.t(), map() -> term())
  @type telemetry_fun :: (term(), map() -> term())
  @type status_fun :: (map() -> term())

  @doc """
  Handles a terminal failure for `action`.

  Options:
  - `:retry` - `(provider, model, state -> result)` re-enters the request.
  - `:telemetry` - `(reason, meta -> :ok)` records the failover decision.
  - `:status` - `(payload -> :ok)` reports the failover to the session.

  Returns the retry result, or `{:error, reason}` when failover stops.
  """
  @spec handle(action(), term(), map() | nil, keyword()) :: term()
  def handle(action, reason, failover_state, opts)
      when action in [:chat_completion, :stream_completion] do
    retry = Keyword.fetch!(opts, :retry)
    telemetry = Keyword.get(opts, :telemetry, fn _reason, _meta -> :ok end)
    status = Keyword.get(opts, :status, fn _payload -> :ok end)
    auth_context = Keyword.get(opts, :auth_context)

    if Policy.classify(:fail_fast, %{reason: reason}) do
      telemetry.(reason, %{action: action, failover_action: :fail_fast})
      {:error, reason}
    else
      state = failover_state || FailoverPolicy.initial_state()
      CooldownRouting.cooldown_auth_profile(auth_context, reason)
      CooldownStore.cooldown_provider(state.current_provider, reason)
      {next, next_state} = FailoverPolicy.next_action(reason, state)

      dispatch(next, next_state, action, reason, %{
        retry: retry,
        telemetry: telemetry,
        status: status
      })
    end
  end

  defp dispatch(:retry_same, next_state, action, reason, deps) do
    report(:retry_same, next_state, action, reason, %{}, deps)

    deps.retry.(next_state.current_provider, next_state.current_model, next_state)
  end

  defp dispatch({:fallback_model, provider, model}, next_state, action, reason, deps) do
    report(:fallback_model, next_state, action, reason, %{provider: provider, model: model}, deps)

    deps.retry.(provider, model, next_state)
  end

  defp dispatch({:fallback_provider, provider, model}, next_state, action, reason, deps) do
    report(
      :fallback_provider,
      next_state,
      action,
      reason,
      %{provider: provider, model: model},
      deps
    )

    deps.retry.(provider, model, next_state)
  end

  defp dispatch(:stop, next_state, action, reason, deps) do
    attempts = next_state |> FailoverPolicy.summarize_attempts() |> Map.get(:attempts, [])

    report(:stop, next_state, action, reason, %{failover_attempts: length(attempts)}, deps)

    {:error, reason}
  end

  defp report(failover_action, next_state, action, reason, extra, deps) do
    deps.telemetry.(reason, Map.merge(%{action: action, failover_action: failover_action}, extra))

    deps.status.(
      Map.merge(
        %{
          kind: :failover,
          action: action,
          failover_action: failover_action,
          provider: next_state.current_provider,
          model: next_state.current_model,
          reason: CooldownRouting.reason_label(reason)
        },
        extra
      )
    )
  end
end
