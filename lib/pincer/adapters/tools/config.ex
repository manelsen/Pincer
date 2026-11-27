defmodule Pincer.Adapters.Tools.Config do
  @moduledoc """
  Tools for managing Pincer configuration in real time.
  """
  @behaviour Pincer.Ports.Tool

  @impl true
  def spec do
    %{
      name: "change_model",
      description: "Changes Pincer's default model in the configuration file.",
      parameters: %{
        type: "object",
        properties: %{
          model_id: %{
            type: "string",
            description:
              "O ID do modelo (ex: 'openrouter/free', 'claude-sonnet-5-5', 'gemini-3.8-flash', 'glm-5.3', 'gpt-6.2-sol')"
          },
          provider: %{
            type: "string",
            description:
              "O provedor do modelo (ex: 'openrouter', 'groq', 'anthropic', 'google', 'openai', 'z_ai', 'ollama')"
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

    case Pincer.Infra.Config.set_model(model_id, provider) do
      {:ok, mid, p} ->
        {:ok, "Model changed successfully to #{mid} on provider #{p}."}

      {:error, reason} ->
        {:error, "Error changing model: #{inspect(reason)}"}
    end
  end
end
