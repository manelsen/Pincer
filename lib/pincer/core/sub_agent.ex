defmodule Pincer.Core.SubAgent do
  @moduledoc """
  Manages the execution of asynchronous tasks (tools) triggered by the Session Agent.
  Allows Pincer to stay "awake" while performing heavy work.
  """
  use Task, restart: :temporary
  require Logger
  alias Pincer.Ports.ToolRegistry

  @doc """
  Starts the execution of a tool in background.
  Notifies the caller process (Session) when complete.
  """
  def start_task(session_pid, tool_call) do
    Task.start(fn ->
      execute(session_pid, tool_call)
    end)
  end

  defp execute(
         session_pid,
         %{"id" => call_id, "function" => %{"name" => name, "arguments" => args_json}} = _call
       ) do
    Logger.info("Sub-agent starting task: #{name} (ID: #{call_id})")

    # Decodes arguments if needed
    args =
      case Jason.decode(args_json) do
        {:ok, decoded} -> decoded
        _ -> args_json
      end

    # Delegate 100% to the ToolRegistry Port
    result =
      case ToolRegistry.execute_tool(name, args) do
        {:ok, content} -> content
        {:error, :tool_not_found} -> "Tool #{name} not found."
        {:error, reason} -> "Error in tool #{name}: #{inspect(reason)}"
      end

    # Sends the result back to the Session
    send(
      session_pid,
      {:tool_result,
       %{
         "role" => "tool",
         "tool_call_id" => call_id,
         "name" => name,
         "content" => result
       }}
    )
  end
end
