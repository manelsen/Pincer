defmodule Pincer.Core.Graph.State do
  @moduledoc """
  Represents the immutable state of an agent execution cycle.
  This is the context passed between the pure nodes in the graph.
  """

  defstruct [
    :session_id,
    :history,
    :workspace_path,
    :model_override,
    :depth,
    :max_depth,
    # :planning, :calling_llm, :executing_tools, :done, :error
    :status,
    # Stores the latest LLM response text or struct
    :last_response,
    # Pending tool calls to execute
    :tool_calls,
    # Results from executed tools
    :tool_results,
    # Stores error message if status == :error
    :error_reason
  ]

  @type status :: :planning | :calling_llm | :executing_tools | :done | :error

  @type t :: %__MODULE__{
          session_id: String.t(),
          history: list(map()),
          workspace_path: String.t(),
          model_override: map() | nil,
          depth: non_neg_integer(),
          max_depth: non_neg_integer(),
          status: status(),
          last_response: any(),
          tool_calls: list(map()),
          tool_results: list(map()),
          error_reason: String.t() | nil
        }

  @doc "Initializes a new execution state."
  def new(session_id, history, opts \\ []) do
    %__MODULE__{
      session_id: session_id,
      history: history,
      workspace_path: Keyword.get(opts, :workspace_path, "."),
      model_override: Keyword.get(opts, :model_override),
      depth: 0,
      max_depth: Keyword.get(opts, :max_depth, 15),
      status: :planning,
      last_response: nil,
      tool_calls: [],
      tool_results: [],
      error_reason: nil
    }
  end
end
