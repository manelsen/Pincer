defmodule Pincer.Core.Graph.Nodes do
  @moduledoc """
  The Functional Core of the Cyclic Graph execution model.
  Contains only PURE functions that transition state and emit actions (edges).
  Never performs side effects (no network, no file IO).
  """

  alias Pincer.Core.Graph.State

  @doc """
  Evaluates the current state and determines the next edge/action to take.
  """
  @spec next(State.t()) :: {State.t(), tuple()}
  def next(%State{status: :planning} = state) do
    if state.depth > state.max_depth do
      new_state = %{state | status: :error, error_reason: "Max recursion depth reached."}
      {new_state, {:emit_error, new_state.error_reason}}
    else
      new_state = %{state | status: :calling_llm}
      {new_state, {:call_llm, new_state}}
    end
  end

  def next(%State{status: :executing_tools, tool_calls: calls} = state) do
    if calls == [] do
      # Should not happen, but safeguard
      new_state = %{state | status: :planning}
      {new_state, {:continue, nil}}
    else
      {state, {:execute_tools, calls}}
    end
  end

  def next(%State{status: :done} = state) do
    {state, {:finish, state.last_response}}
  end

  def next(%State{status: :error} = state) do
    {state, {:emit_error, state.error_reason}}
  end

  @doc """
  Pure transition: receives the raw response from the LLM and decides the next state.
  """
  @spec on_llm_response(State.t(), list(map()), list(map())) :: State.t()
  def on_llm_response(%State{} = state, new_messages, tool_calls) do
    updated_history = state.history ++ new_messages

    if tool_calls == [] do
      %{
        state
        | history: updated_history,
          status: :done,
          last_response: List.last(new_messages)["content"]
      }
    else
      %{state | history: updated_history, status: :executing_tools, tool_calls: tool_calls}
    end
  end

  @doc """
  Pure transition: processes results from tool executions and cycles back to planning.
  """
  @spec on_tool_results(State.t(), list(map())) :: State.t()
  def on_tool_results(%State{} = state, tool_results_messages) do
    # Append the tool results to history and increment depth
    # This forms the CYCLE in the graph: back to planning.
    %{
      state
      | history: state.history ++ tool_results_messages,
        status: :planning,
        depth: state.depth + 1,
        tool_calls: [],
        tool_results: []
    }
  end
end
