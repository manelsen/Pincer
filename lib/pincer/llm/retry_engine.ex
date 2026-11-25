defmodule Pincer.LLM.RetryEngine do
  @moduledoc "Runs resolved chat and stream requests through retry and failover."

  require Logger

  alias Pincer.Core.Policy
  alias Pincer.Core.Telemetry, as: CoreTelemetry
  alias Pincer.LLM.{CooldownRouting, FailoverDispatch, RetrySettings, StreamFallback, ToolParser}
  alias PincerPorts.Structs.Usage

  @type request :: %{
          adapter: module(),
          messages: list(),
          model: String.t() | nil,
          config: map(),
          tools: list(),
          failover_state: map() | nil,
          auth_context: map() | nil
        }

  @doc "Runs the resolved route, calling `dispatch` when recovery selects a route again."
  @spec run(FailoverDispatch.action(), request(), (atom(), list(), keyword() -> term())) :: term()
  def run(action, request, dispatch) do
    policy = RetrySettings.load()

    state = %{
      action: action,
      request: request,
      dispatch: dispatch,
      policy: policy,
      retries: policy.max_retries,
      delay: policy.initial_backoff,
      started_at_ms: System.monotonic_time(:millisecond)
    }

    attempt(state)
  end

  @doc "Normalizes provider error wrappers into the domain reason consumed by retry policies."
  @spec normalize_reason(term()) :: term()
  def normalize_reason({:error, reason}), do: normalize_reason(reason)
  def normalize_reason({:EXIT, reason}), do: normalize_reason(reason)
  def normalize_reason(%Req.TransportError{reason: reason}), do: {:transport_error, reason}
  def normalize_reason(reason), do: reason

  defp attempt(%{request: request, action: action} = state) do
    result =
      apply(request.adapter, action, [
        request.messages,
        request.model,
        request.config,
        request.tools
      ])

    case result do
      {:ok, message, usage} when action == :chat_completion ->
        clear_cooldowns(request)
        {:ok, ToolParser.parse(message), Usage.normalize_optional(usage)}

      {:ok, stream, usage} when action == :stream_completion ->
        stream_result(state, stream, {:usage, usage})

      {:ok, stream} when action == :stream_completion ->
        stream_result(state, stream, :no_usage)

      {:ok, result} ->
        clear_cooldowns(request)
        {:ok, result}

      {:error, reason} ->
        handle_error(state, normalize_reason(reason))
    end
  end

  defp clear_cooldowns(request) do
    CooldownRouting.clear_provider_cooldown(request.failover_state)
    CooldownRouting.clear_auth_profile_cooldown(request.auth_context)
  end

  defp stream_result(state, stream, usage) do
    clear_cooldowns(state.request)

    if valid_stream?(stream) do
      case usage do
        {:usage, usage} -> {:ok, stream, Usage.normalize_optional(usage)}
        :no_usage -> {:ok, stream}
      end
    else
      StreamFallback.stream_to_chat(
        :stream_completion,
        {:invalid_stream_response, stream},
        fn -> attempt(%{state | action: :chat_completion}) end,
        fn reason ->
          CoreTelemetry.emit_error(reason, %{
            action: :stream_completion,
            reason: :fallback_chat_failed
          })
        end
      )
    end
  end

  defp valid_stream?(stream) do
    if Enumerable.impl_for(stream) do
      _ = Enum.take(stream, 0)
      true
    else
      false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp handle_error(state, reason) do
    cond do
      quota_exhausted?(reason) ->
        Logger.error("Out of credits/quota detected. Failing fast without retry.")
        CoreTelemetry.emit_error(reason, %{action: state.action, reason: :quota_exhausted})
        {:error, reason}

      state.retries > 0 and Policy.classify(:retryable, %{reason: reason}) ->
        retry(state, reason)

      true ->
        failover(state, reason)
    end
  end

  defp retry(state, reason) do
    max_elapsed_ms = state.policy.max_elapsed_ms
    elapsed_ms = System.monotonic_time(:millisecond) - state.started_at_ms

    if elapsed_ms >= max_elapsed_ms do
      Logger.warning(
        "Retry deadline reached (#{elapsed_ms}ms >= #{max_elapsed_ms}ms). Stopping retries."
      )

      retry_timeout(state.action, reason, :deadline_reached)
    else
      base_wait =
        case Policy.budget(:retry_after_ms, %{
               reason: reason,
               elapsed_ms: elapsed_ms,
               max_elapsed_ms: max_elapsed_ms
             }) do
          ms when is_integer(ms) and ms > 0 -> ms
          _ -> state.delay
        end

      wait_ms = with_jitter(base_wait, state.policy.jitter_ratio)

      if elapsed_ms + wait_ms > max_elapsed_ms do
        Logger.warning(
          "Retry deadline would be exceeded by next wait (elapsed=#{elapsed_ms}ms, wait=#{wait_ms}ms, max=#{max_elapsed_ms}ms)."
        )

        retry_timeout(state.action, reason, :deadline_exceeded_by_wait)
      else
        wait_for_retry(state, reason, wait_ms, base_wait)
      end
    end
  end

  defp retry_timeout(action, reason, timeout_reason) do
    CoreTelemetry.emit_error({:retry_timeout, reason}, %{action: action, reason: timeout_reason})
    {:error, {:retry_timeout, reason}}
  end

  defp wait_for_retry(state, reason, wait_ms, base_wait) do
    meta = %{action: state.action, wait_ms: wait_ms, retries_left: state.retries}
    CoreTelemetry.emit_retry(reason, meta)

    reason_label = CooldownRouting.reason_label(reason)
    notify_runtime_status(Map.merge(meta, %{kind: :retry_wait, reason: reason_label}))

    Logger.warning(
      "Transient LLM failure (#{reason_label}). Waiting #{wait_ms}ms... (Retries left: #{state.retries})"
    )

    receive do
      {:model_changed, provider, model} ->
        {provider, model} = drain_model_changed(provider, model)
        Logger.info("[CLIENT] Model changed mid-backoff to #{provider}. SWAPPING NOW.")

        state.dispatch.(state.action, state.request.messages,
          provider: provider,
          model: model,
          tools: state.request.tools
        )
    after
      wait_ms ->
        next_delay = min(max(state.delay * 2, base_wait), state.policy.max_backoff)
        attempt(%{state | retries: state.retries - 1, delay: next_delay})
    end
  end

  defp failover(%{request: request} = state, reason) do
    FailoverDispatch.handle(state.action, reason, request.failover_state,
      auth_context: request.auth_context,
      telemetry: &CoreTelemetry.emit_error/2,
      status: &notify_runtime_status/1,
      retry: fn provider, model, next_state ->
        state.dispatch.(state.action, request.messages,
          provider: provider,
          model: model,
          tools: request.tools,
          failover_state: next_state
        )
      end
    )
  end

  defp drain_model_changed(provider, model) do
    receive do
      {:model_changed, next_provider, next_model} ->
        drain_model_changed(next_provider, next_model)
    after
      0 -> {provider, model}
    end
  end

  defp quota_exhausted?({:http_error, 429, body, _meta}),
    do: quota_exhausted?({:http_error, 429, body})

  defp quota_exhausted?({:http_error, 429, body}) when is_binary(body) do
    String.contains?(body, ["余额不足", "insufficient_quota"])
  end

  defp quota_exhausted?(_), do: false

  defp with_jitter(base_ms, jitter_ratio) when is_integer(base_ms) and base_ms >= 0 do
    jitter = trunc(base_ms * jitter_ratio)

    if jitter <= 0 do
      base_ms
    else
      random_delta = :rand.uniform(jitter * 2 + 1) - jitter - 1
      max(0, base_ms + random_delta)
    end
  end

  defp notify_runtime_status(payload) do
    case Process.get(:session_pid) do
      pid when is_pid(pid) -> send(pid, {:llm_runtime_status, payload})
      _ -> :ok
    end

    :ok
  end
end
