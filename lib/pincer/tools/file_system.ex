defmodule Pincer.Tools.FileSystem do
  @moduledoc """
  Ferramentas para manipulação do sistema de arquivos.
  """
  @behaviour Pincer.Tool
  require Logger

  @impl true
  def spec do
    %{
      name: "file_system",
      description: "Gerencia arquivos e diretórios.",
      parameters: %{
        type: "object",
        properties: %{
          action: %{
            type: "string",
            description: "Ação a executar: 'list' ou 'read'",
            enum: ["list", "read"]
          },
          path: %{
            type: "string",
            description: "Caminho do arquivo ou diretório (default: '.' para list)"
          }
        },
        required: ["action"]
      }
    }
  end

  @impl true
  def execute(args) do
    action = Map.get(args, "action")
    path = Map.get(args, "path", ".")

    case action do
      "list" -> 
        case File.ls(path) do
          {:ok, files} -> {:ok, "Arquivos em '#{path}':\n" <> Enum.join(files, "\n")}
          {:error, reason} -> {:error, "Erro ao listar: #{inspect(reason)}"}
        end
      "read" ->
        case File.read(path) do
          {:ok, content} -> {:ok, content}
          {:error, reason} -> {:error, "Erro ao ler: #{inspect(reason)}"}
        end
      _ -> {:error, "Ação inválida."}
    end
  end
end
