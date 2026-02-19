defmodule Pincer.AI.Embeddings do
  @moduledoc """
  Gerencia o modelo de embeddings local via Nx.Serving.
  """
  require Logger

  @model_repo "thenlper/gte-small"

  def start_link(_opts) do
    Logger.info("Carregando modelo de embeddings: #{@model_repo}")
    {:ok, model_info} = Bumblebee.load_model({:hf, @model_repo})
    {:ok, tokenizer} = Bumblebee.load_tokenizer({:hf, @model_repo})

    serving = Bumblebee.Text.text_embedding(model_info, tokenizer,
      output_pool: :mean_pooling,
      output_attribute: :hidden_state
    )

    Nx.Serving.start_link(serving: serving, name: :pincer_embeddings)
  end

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :worker}
  end

  def generate(text) do
    try do
      # O Nx.Serving.run/2 retorna o resultado diretamente para o processo
      case Nx.Serving.run(:pincer_embeddings, text) do
        %{embedding: tensor} -> tensor
        # Se for uma lista (batch)
        [%{embedding: tensor} | _] -> tensor
        _ -> fallback_tensor()
      end
    rescue
      _ -> fallback_tensor()
    end
  end

  defp fallback_tensor, do: Nx.broadcast(0.0, {384})

  def similarity(v1, v2) do
    # Garante que v1 e v2 são tensores válidos e não nil
    v1 = v1 || fallback_tensor()
    v2 = v2 || fallback_tensor()

    dot = Nx.dot(v1, v2)
    norm1 = Nx.LinAlg.norm(v1)
    norm2 = Nx.LinAlg.norm(v2)
    
    # Evita divisão por zero
    if Nx.to_number(norm1) == 0 or Nx.to_number(norm2) == 0 do
      0.0
    else
      dot |> Nx.divide(Nx.multiply(norm1, norm2)) |> Nx.to_number()
    end
  end
end
