defmodule Pincer.Core.Graph.Runner do
  @moduledoc """
  The Imperative Shell for the Cyclic Graph execution model.
  Responsible for managing the execution loop, performing side effects,
  and feeding results back into the pure Nodes.
  """
  require Logger
  alias Pincer.Core.Graph.{State, Nodes}

  @doc """
  Starts the graph execution loop given an initial state.
  """
  def run(%State{} = initial_state, deps) do
    loop(initial_state, deps)
  end

  # The main execution loop (The Edges)
  defp loop(%State{} = state, deps) do
    # 1. Ask the Functional Core what to do next
    {new_state, action} = Nodes.next(state)

    # 2. Perform the imperative side-effect based on the action
    case action do
      {:call_llm, _state_to_use} ->
        Logger.info("[GRAPH] Edge: Calling LLM (Depth: #{new_state.depth})")
        execute_llm_edge(new_state, deps)

      {:execute_tools, calls} ->
        Logger.info("[GRAPH] Edge: Executing #{length(calls)} tools")
        execute_tools_edge(new_state, calls, deps)

      {:continue, _} ->
        # Just loop back with the new state
        loop(new_state, deps)

      {:finish, final_response} ->
        Logger.info("[GRAPH] Edge: Execution finished successfully.")
        {:ok, new_state.history, final_response, %{}}

      {:emit_error, reason} ->
        Logger.error("[GRAPH] Edge: Execution failed - #{reason}")
        {:error, reason}
    end
  end

  # --- Edges (Imperative Side-Effects) ---

  defp execute_llm_edge(state, deps) do
    tools_spec = deps.tool_registry.list_tools()
    
    # In a full implementation, this would use stream_completion and handle tokens
    # For the graph abstraction, we treat the network call as a discrete edge.
    case deps.llm_client.chat_completion(state.history, [tools: tools_spec]) do
      {:ok, response} ->
        # Parse response into standard message and tool calls
        message = response["choices"] |> hd() |> Map.get("message")
        tool_calls = Map.get(message, "tool_calls", [])
        
        # We must save the assistant's message to history before executing tools
        new_messages = [message]
        
        # 3. Feed the result back to the pure Node to get the next state
        next_state = Nodes.on_llm_response(state, new_messages, tool_calls)
        
        # Continue the loop
        loop(next_state, deps)

      {:error, reason} ->
        # Error transition
        err_state = %{state | status: :error, error_reason: inspect(reason)}
        loop(err_state, deps)
    end
  end

  defp execute_tools_edge(state, tool_calls, deps) do
    # 1. Execute tools imperatively
    results = Enum.map(tool_calls, fn call ->
      function_name = get_in(call, ["function", "name"])
      arguments = get_in(call, ["function", "arguments"])
      call_id = Map.get(call, "id")

      # Try to parse args if it's a JSON string
      args_map = case arguments do
        s when is_binary(s) -> 
          case Jason.decode(s) do
            {:ok, m} -> m
            _ -> %{}
          end
        m when is_map(m) -> m
        _ -> %{}
      end

      # Execute via registry
      result_text = case deps.tool_registry.execute(function_name, args_map) do
        {:ok, res} -> res
        {:error, err} -> "Error: #{err}"
      end

      # Format to LLM standard tool message
      %{
        "role" => "tool",
        "name" => function_name,
        "tool_call_id" => call_id,
        "content" => to_string(result_text)
      }
    end)

    # 2. Feed results back to pure Node to transition state
    next_state = Nodes.on_tool_results(state, results)

    # Continue the cycle
    loop(next_state, deps)
  end
end
