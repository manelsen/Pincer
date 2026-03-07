defmodule Pincer.AI.Embeddings do
  @moduledoc """
  Manages the local embeddings model via Nx.Serving.
  """
  require Logger

  @model_repo "thenlper/gte-small"

  def start_link(_opts) do
    if Code.ensure_loaded?(Bumblebee) do
      Logger.info("Loading embeddings model: #{@model_repo}")
      {:ok, model_info} = apply(Bumblebee, :load_model, [{:hf, @model_repo}])
      {:ok, tokenizer} = apply(Bumblebee, :load_tokenizer, [{:hf, @model_repo}])

      serving = apply(Bumblebee.Text, :text_embedding, [model_info, tokenizer,
        [output_pool: :mean_pooling, output_attribute: :hidden_state]])

      apply(Nx.Serving, :start_link, [[serving: serving, name: :pincer_embeddings]])
    else
      Logger.warning("Bumblebee is not loaded. Local embeddings disabled.")
      :ignore
    end
  end

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :worker}
  end

  def generate(text) do
    if Code.ensure_loaded?(Nx.Serving) do
      try do
        case apply(Nx.Serving, :run, [:pincer_embeddings, text]) do
          %{embedding: tensor} -> tensor
          [%{embedding: tensor} | _] -> tensor
          _ -> fallback_tensor()
        end
      rescue
        _ -> fallback_tensor()
      end
    else
      fallback_tensor()
    end
  end

  defp fallback_tensor do
    if Code.ensure_loaded?(Nx) do
      apply(Nx, :broadcast, [0.0, {384}])
    else
      nil
    end
  end

  def similarity(v1, v2) do
    if Code.ensure_loaded?(Nx) do
      v1 = v1 || fallback_tensor()
      v2 = v2 || fallback_tensor()

      dot = apply(Nx, :dot, [v1, v2])
      norm1 = apply(Nx.LinAlg, :norm, [v1])
      norm2 = apply(Nx.LinAlg, :norm, [v2])
      
      if apply(Nx, :to_number, [norm1]) == 0 or apply(Nx, :to_number, [norm2]) == 0 do
        0.0
      else
        dot 
        |> then(&apply(Nx, :divide, [&1, apply(Nx, :multiply, [norm1, norm2])])) 
        |> then(&apply(Nx, :to_number, [&1]))
      end
    else
      0.0
    end
  end
end
