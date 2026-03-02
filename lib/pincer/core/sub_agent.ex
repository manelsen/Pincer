defmodule Pincer.Core.SubAgent do
  @moduledoc """
  Manages the execution of asynchronous tasks (tools) triggered by the Session Agent.
  Allows Pincer to stay "awake" while performing heavy work.
  """
  use Task, restart: :temporary
  require Logger

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

    # 1. Try native tools
    module = find_native_tool_module(name)

    result =
      cond do
        module ->
          case module.execute(args) do
            {:ok, content} -> content
            {:error, reason} -> "Error in native tool #{name}: #{inspect(reason)}"
          end

        # 2. Try MCP tools
        true ->
          case Pincer.Connectors.MCP.Manager.execute_tool(name, args) do
            {:ok, content} -> content
            {:error, :tool_not_found} -> "Tool #{name} not found."
            {:error, reason} -> "Error in MCP tool #{name}: #{inspect(reason)}"
          end
      end

    # Sends the result back to the Session via Cast or Call message
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

  defp find_native_tool_module(name) do
    # Temporary fixed list
    tools = [
      Pincer.Tools.FileSystem,
      Pincer.Tools.Config,
      Pincer.Tools.Scheduler,
      Pincer.Tools.GitHub
    ]

    Enum.find(tools, fn m -> m.spec().name == name end)
  end
end
