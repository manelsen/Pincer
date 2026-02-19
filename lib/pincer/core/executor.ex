defmodule Pincer.Core.Executor do
  @moduledoc """
  Executor Unificado (O Agente Polímata).
  Substitui a complexidade de SMEs por um único loop de raciocínio + ferramentas.
  """
  require Logger
  alias Pincer.LLM.Client
  alias Pincer.Connectors.MCP.Manager, as: MCPManager

  @native_tools [
    Pincer.Tools.FileSystem,
    Pincer.Tools.Config,
    Pincer.Tools.Scheduler,
    Pincer.Tools.GitHub
  ]

  def start(session_pid, session_id, history) do
    Task.start(fn ->
      run(session_pid, session_id, history)
    end)
  end

  defp run(session_pid, session_id, history) do
    Logger.info("[EXECUTOR] Iniciando ciclo para #{session_id}")
    
    # Injeta um System Prompt de Agente Polímata se não houver
    # Ou confia no que veio da Sessão (que já tem Identity/Soul)
    
    try do
      case run_loop(history, session_id, session_pid, 0) do
        {:ok, final_history, response} ->
          send(session_pid, {:executor_finished, final_history, response})

        {:error, reason} ->
          send(session_pid, {:executor_failed, reason})
      end
    rescue
      e ->
        send(session_pid, {:executor_failed, e})
    end
  end

  defp run_loop(history, session_id, session_pid, depth) do
    if depth > 10, do: raise "Recursão excessiva no Executor"

    # Verificação de Loop de Ferramentas
    if loop_detected?(history) do
      send(session_pid, {:executor_failed, "Loop de ferramentas detectado. Abortando."})
      {:error, :tool_loop}
    else
      do_run_loop(history, session_id, session_pid, depth)
    end
  end

  defp do_run_loop(history, session_id, session_pid, depth) do
    # Notifica que está pensando (opcional, pode ser muito verboso)
    # send(session_pid, {:agent_thinking, "..."})

    case Client.chat_completion(history, tools: get_tools()) do
      {:ok, %{"tool_calls" => tool_calls} = assistant_msg} when not is_nil(tool_calls) ->
        tool_names = Enum.map(tool_calls, fn tc -> tc["function"]["name"] end) |> Enum.join(", ")
        
        # Notifica uso de ferramenta
        send(session_pid, {:sme_tool_use, tool_names})

        tool_results = Enum.map(tool_calls, fn call -> execute_tool(call) end)
        new_history = history ++ [assistant_msg] ++ tool_results
        
        run_loop(new_history, session_id, session_pid, depth + 1)

      {:ok, %{"content" => content} = assistant_msg} ->
        {:ok, history ++ [assistant_msg], content}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute_tool(%{"id" => call_id, "function" => %{"name" => name, "arguments" => args_json}}) do
    Logger.info("[TOOL] Executando #{name}")
    args = case Jason.decode(args_json) do {:ok, d} -> d; _ -> args_json end
    
    result = cond do
      module = Enum.find(@native_tools, fn m -> m.spec().name == name end) ->
        case module.execute(args) do
          {:ok, c} -> c
          {:error, r} -> "Erro: #{inspect(r)}"
        end
      true ->
        case MCPManager.execute_tool(name, args) do
          {:ok, c} -> c
          {:error, :tool_not_found} -> "Ferramenta #{name} não encontrada."
          {:error, r} -> "Erro: #{inspect(r)}"
        end
    end

    %{"role" => "tool", "tool_call_id" => call_id, "name" => name, "content" => to_string(result)}
  end

  defp get_tools do
    native = Enum.map(@native_tools, fn m -> %{"type" => "function", "function" => m.spec()} end)
    mcp = MCPManager.get_all_tools() |> Enum.map(fn s -> %{"type" => "function", "function" => s} end)
    native ++ mcp
  end

  defp loop_detected?(history) do
    tool_calls = Enum.filter(Enum.take(history, -6), fn 
      %{"tool_calls" => calls} -> not is_nil(calls)
      _ -> false
    end)

    if length(tool_calls) >= 3 do
      first = List.first(tool_calls)["tool_calls"]
      Enum.all?(tool_calls, fn msg -> msg["tool_calls"] == first end)
    else
      false
    end
  end
end
