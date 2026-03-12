defmodule Pincer.Ports.ToolRegistry do
  @moduledoc "Port for discovering and executing tools."

  @callback list_tools() :: [map()]
  @callback execute_tool(String.t(), map(), map()) :: {:ok, term()} | {:error, term()}

  # --- Dispatcher ---

  defp adapters do
    # Pure dynamic lookup from configuration. No hardcoded adapters here.
    # Guard against nil stored explicitly (e.g., test on_exit restoring unset env).
    Application.get_env(:pincer, :tool_adapters) || []
  end

  def list_tools do
    Enum.flat_map(adapters(), fn adapter ->
      if Code.ensure_loaded?(adapter), do: adapter.list_tools(), else: []
    end)
  end

  def execute_tool(name, args, context \\ %{}) do
    Enum.find_value(adapters(), {:error, "Tool not found: #{name}"}, fn adapter ->
      if Code.ensure_loaded?(adapter) do
        case adapter.execute_tool(name, args, context) do
          {:error, "Tool not found" <> _} -> nil
          result -> result
        end
      else
        nil
      end
    end)
  end
end
