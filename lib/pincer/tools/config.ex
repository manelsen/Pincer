defmodule Pincer.Tools.Config do
  @moduledoc """
  Ferramentas para gerenciar a configuração do Pincer em tempo real.
  """
  @behaviour Pincer.Tool
  require Logger

  @impl true
  def spec do
    %{
      name: "change_model",
      description: "Altera o modelo padrão do Pincer no arquivo de configuração.",
      parameters: %{
        type: "object",
        properties: %{
          model_id: %{
            type: "string",
            description: "O ID do modelo (ex: 'kimi-k2.5-free', 'glm-5-free', 'stepfun/step-3.5-flash:free')"
          },
          provider: %{
            type: "string",
            description: "O provedor do modelo ('opencode_zen' ou 'openrouter')"
          }
        },
        required: ["model_id"]
      }
    }
  end

  @impl true
  def execute(args) do
    model_id = Map.get(args, "model_id")
    provider = Map.get(args, "provider")

    case Pincer.Config.set_model(model_id, provider) do
      {:ok, mid, p} ->
        {:ok, "Modelo alterado com sucesso para #{mid} no provedor #{p}."}
      {:error, reason} ->
        {:error, "Erro ao alterar modelo: #{inspect(reason)}"}
    end
  end
end
