defmodule Pincer.Core.SubAgent do
  @moduledoc """
  Gerencia a execução de tarefas assíncronas (ferramentas) disparadas pelo Agente de Sessão.
  Permite que o Pincer continue "acordado" enquanto realiza trabalhos pesados.
  """
  use Task, restart: :temporary
  require Logger

  @doc """
  Inicia a execução de uma ferramenta em background.
  Notifica o processo chamador (Session) quando concluir.
  """
  def start_task(session_pid, tool_call) do
    Task.start(fn ->
      execute(session_pid, tool_call)
    end)
  end

  defp execute(session_pid, %{"id" => call_id, "function" => %{"name" => name, "arguments" => args_json}} = _call) do
    Logger.info("Sub-agente iniciando tarefa: #{name} (ID: #{call_id})")

    # Decodifica argumentos se necessário
    args =
      case Jason.decode(args_json) do
        {:ok, decoded} -> decoded
        _ -> args_json
      end

    # 1. Tenta ferramentas nativas
    module = find_native_tool_module(name)

    result =
      cond do
        module ->
          case module.execute(args) do
            {:ok, content} -> content
            {:error, reason} -> "Erro na ferramenta nativa #{name}: #{inspect(reason)}"
          end

        # 2. Tenta ferramentas MCP
        true ->
          case Pincer.Connectors.MCP.Manager.execute_tool(name, args) do
            {:ok, content} -> content
            {:error, :tool_not_found} -> "Ferramenta #{name} não encontrada."
            {:error, reason} -> "Erro na ferramenta MCP #{name}: #{inspect(reason)}"
          end
      end

    # Envia o resultado de volta para a Sessão via mensagem Cast ou Call
    send(session_pid, {:tool_result, %{
      "role" => "tool",
      "tool_call_id" => call_id,
      "name" => name,
      "content" => result
    }})
  end

  defp find_native_tool_module(name) do
    # Lista fixa temporária
    tools = [
      Pincer.Tools.FileSystem,
      Pincer.Tools.Config,
      Pincer.Tools.Scheduler,
      Pincer.Tools.GitHub
    ]

    Enum.find(tools, fn m -> m.spec().name == name end)
  end
end
