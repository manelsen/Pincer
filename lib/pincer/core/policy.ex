defmodule Pincer.Core.Policy do
  @moduledoc """
  Unified policy facade for cross-cutting runtime decisions.

  This module provides a stable entrypoint for policy categories:
  - Tool
  - LLM
  - Session
  - Memory
  - Channel
  - Project

  The initial implementation focuses on delegating to existing policy modules
  so behavior remains unchanged while call sites converge to a single API.
  """

  alias Pincer.Core.AccessPolicy
  alias Pincer.Core.ChannelEventPolicy
  alias Pincer.Core.EmptyResponseRecoveryPolicy
  alias Pincer.Core.RetryPolicy
  alias Pincer.Core.SessionScopePolicy
  alias Pincer.Core.StatusMessagePolicy
  alias Pincer.Core.StreamingPolicy
  alias Pincer.Core.TurnOutcomePolicy

  @doc """
  Access-oriented allow/deny decisions.
  """
  @spec allow?(atom(), map()) :: term()
  def allow?(:dm_access, %{channel: channel, sender_id: sender_id} = attrs) do
    AccessPolicy.authorize_dm(channel, sender_id, Map.get(attrs, :config, %{}))
  end

  def allow?(_kind, _attrs), do: {:error, :unsupported_allow_policy}

  @doc """
  Routing decisions for session and channel flow.
  """
  @spec route(atom(), map()) :: term()
  def route(:session_scope, %{channel: channel, context: context} = attrs) do
    SessionScopePolicy.resolve(channel, context, Map.get(attrs, :config, %{}))
  end

  def route(_kind, _attrs), do: {:error, :unsupported_route_policy}

  @doc """
  Budget/deadline decisions.
  """
  @spec budget(atom(), map()) :: term()
  def budget(:retry_after_ms, %{
        reason: reason,
        elapsed_ms: elapsed_ms,
        max_elapsed_ms: max_elapsed_ms
      }) do
    RetryPolicy.retry_after_ms(reason, elapsed_ms, max_elapsed_ms)
  end

  def budget(_kind, _attrs), do: {:error, :unsupported_budget_policy}

  @doc """
  Guard checks and transformations that may raise in future policy classes.
  """
  @spec guard!(atom(), map()) :: term()
  def guard!(:approval_message, %{channel: channel, command: command}) do
    ChannelEventPolicy.approval_message(channel, command)
  end

  def guard!(:status_message, %{state: state, text: text}) do
    StatusMessagePolicy.next_action(state, text)
  end

  def guard!(:stream_partial, %{state: state, token: token, now_ms: now_ms} = attrs) do
    StreamingPolicy.on_partial(state, token, now_ms, Map.get(attrs, :opts, []))
  end

  def guard!(:stream_final, %{state: state, final_text: final_text}) do
    StreamingPolicy.on_final(state, final_text)
  end

  def guard!(_kind, _attrs), do: raise(ArgumentError, "unsupported guard policy")

  @doc """
  Recovery and outcome policies for resilient turns.
  """
  @spec recover(atom(), map()) :: term()
  def recover(:empty_response_prompt, _attrs), do: EmptyResponseRecoveryPolicy.recovery_prompt()

  def recover(:empty_response_history, %{history: history}) do
    EmptyResponseRecoveryPolicy.retry_history(history)
  end

  def recover(:turn_outcome, %{attrs: attrs}), do: TurnOutcomePolicy.resolve(attrs)
  def recover(_kind, _attrs), do: {:error, :unsupported_recovery_policy}
end
