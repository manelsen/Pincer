defmodule Pincer.Core.Ports.ToolRegistry do
  @moduledoc """
  Port for retrieving available tools.

  In Hexagonal Architecture, this port allows the core Executor to
  remain agnostic of where tools come from (e.g., native modules,
  dynamic MCP servers, or mocked test tools).
  """

  @doc """
  Returns a list of tool modules or specifications.
  """
  @callback list_tools() :: [module() | map()]

  @doc """
  Finds a tool by name and executes it.
  """
  @callback execute_tool(name :: String.t(), args :: map(), context :: map()) :: 
    {:ok, String.t()} | {:error, any()}
end
