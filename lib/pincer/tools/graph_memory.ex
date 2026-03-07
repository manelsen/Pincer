defmodule Pincer.Adapters.Tools.GraphMemory do
  @moduledoc """
  Tool for querying the project's knowledge graph for bug and fix history.

  GraphMemory provides access to a persistent knowledge base that stores
  information about bugs encountered, their symptoms, root causes, and
  the fixes applied. This enables learning from past issues and avoiding
  repeated mistakes.

  ## Purpose

  - **Knowledge Retention**: Remember bugs and solutions across sessions
  - **Pattern Recognition**: Identify recurring issues in specific files
  - **Accelerated Debugging**: Reference previous solutions for similar problems
  - **Documentation**: Historical record of issues and resolutions

  ## Data Structure

  Each entry in the graph contains:

      %{
        bug: "Description of the bug",
        file: "path/to/affected/file.ex",
        fix: "Description of the fix applied",
        timestamp: ~U[2026-02-20 14:30:00Z]
      }

  ## Query Capabilities

  - Retrieve all recorded bugs and fixes
  - Filter by file name or error type
  - Case-insensitive substring matching

  ## Examples

      # Get all history
      iex> Pincer.Adapters.Tools.GraphMemory.execute(%{})
      {:ok, "[{\"bug\":\"Nil error in parser\",\"file\":\"lib/parser.ex\",...}]"}

      # Filter by file name
      iex> Pincer.Adapters.Tools.GraphMemory.execute(%{"filter" => "parser"})
      {:ok, "[{\"bug\":\"Nil error in parser\",\"file\":\"lib/parser.ex\",...}]"}

      # Filter by error type
      iex> Pincer.Adapters.Tools.GraphMemory.execute(%{"filter" => "TypeError"})
      {:ok, "[{\"bug\":\"TypeError in concat\",\"file\":\"lib/utils.ex\",...}]"}

  ## Integration

  This tool integrates with:
  - `Pincer.Storage.Adapters.Graph` - The underlying graph storage
  - Session management for automatic learning
  - Error tracking systems for automated population

  ## Future Enhancements

  - Semantic search using embeddings
  - Related bug suggestions
  - Fix effectiveness scoring

  ## See Also

  - `Pincer.Storage.Adapters.Graph` - Graph storage adapter
  - `Pincer.Ports.Tool` - Tool behaviour specification
  """

  @behaviour Pincer.Ports.Tool
  require Logger
  alias Pincer.Ports.Storage

  @type history_entry :: %{
          bug: String.t(),
          file: String.t(),
          fix: String.t(),
          timestamp: DateTime.t()
        }

  @type spec :: %{
          name: String.t(),
          description: String.t(),
          parameters: map()
        }

  @type execute_result :: {:ok, String.t()} | {:error, String.t()}

  @doc """
  Returns the tool specification for LLM function calling.

  ## Returns

      %{
        name: "graph_history",
        description: "Retrieves the history of bugs and fixes...",
        parameters: %{
          type: "object",
          properties: %{
            filter: %{type: "string", description: "Opcional: termo para filtrar..."}
          }
        }
      }
  """
  @spec spec() :: spec()
  @impl true
  def spec do
    %{
      name: "graph_history",
      description:
        "Retrieves the history of bugs and fixes registered in the project's knowledge graph.",
      parameters: %{
        type: "object",
        properties: %{
          filter: %{
            type: "string",
            description:
              "Optional: term to filter the history search (e.g., a file name or error type)."
          }
        }
      }
    }
  end

  @doc """
  Queries the knowledge graph for bug and fix history.

  Retrieves recorded bugs and their associated fixes from the graph database.
  Results can be optionally filtered by a search term that matches against
  bug descriptions or file paths.

  ## Parameters

    * `filter` (optional) - Search term to filter results. Performs
      case-insensitive substring matching against both bug descriptions
      and file paths.

  ## Returns

    * `{:ok, json_array}` - JSON-encoded array of matching entries
    * `{:ok, message}` - Human-readable message when no results found

  ## Filtering Logic

  When a filter is provided, entries match if the filter string appears
  (case-insensitive) in either:
  - The `bug` field (bug description)
  - The `file` field (file path)

  ## Examples

      iex> Pincer.Adapters.Tools.GraphMemory.execute(%{})
      {:ok, "[{\"bug\":\"NullReference\",\"file\":\"lib/auth.ex\",...}]"}

      iex> Pincer.Adapters.Tools.GraphMemory.execute(%{"filter" => "auth"})
      {:ok, "[{\"bug\":\"NullReference in auth\",\"file\":\"lib/auth.ex\",...}]"}

      iex> Pincer.Adapters.Tools.GraphMemory.execute(%{})
      {:ok, "No bugs or fixes found in the graph yet."}

      iex> Pincer.Adapters.Tools.GraphMemory.execute(%{"filter" => "nonexistent"})
      {:ok, "Nenhum resultado para o filtro 'nonexistent'."}
  """
  @spec execute(map()) :: execute_result()
  @impl true
  def execute(params) do
    Logger.info("[TOOL] Graph History Query: #{inspect(params)}")

    results = Storage.query_history()

    if Enum.empty?(results) do
      {:ok, "No bugs or fixes found in the graph yet."}
    else
      filter_and_respond(results, params["filter"])
    end
  end

  @doc false
  @spec filter_and_respond([history_entry()], String.t() | nil) :: {:ok, String.t()}
  defp filter_and_respond(results, nil), do: {:ok, Jason.encode!(results)}

  defp filter_and_respond(results, filter) do
    filtered = apply_filter(results, filter)

    if Enum.empty?(filtered) do
      {:ok, "No results for filter '#{filter}'."}
    else
      {:ok, Jason.encode!(filtered)}
    end
  end

  @doc false
  @spec apply_filter([history_entry()], String.t()) :: [history_entry()]
  defp apply_filter(results, filter) do
    filter_lower = String.downcase(filter)

    Enum.filter(results, fn r ->
      String.contains?(String.downcase(r.bug), filter_lower) ||
        String.contains?(String.downcase(r.file), filter_lower)
    end)
  end
end
