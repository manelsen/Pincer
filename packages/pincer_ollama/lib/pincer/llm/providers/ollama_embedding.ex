defmodule Pincer.LLM.Providers.OllamaEmbedding do
  @moduledoc """
  Embedding adapter for Ollama (local inference).

  Particularities:
  - Endpoint: `POST http://localhost:11434/api/embeddings` (configurable).
  - Payload: `{"model": "<model>", "prompt": "<text>"}`.
  - Returns `{:ok, [float()]}` with the raw embedding vector.
  - No API key required.
  - All other `Pincer.LLM.Provider` callbacks delegate to `:not_implemented`.
  """
  @behaviour Pincer.LLM.Provider

  require Logger

  @default_base_url "http://localhost:11434"
  @default_model "nomic-embed-text"
  @connect_timeout 5_000
  @timeout 60_000

  @impl true
  def chat_completion(_messages, _model, _config, _tools), do: {:error, :not_implemented}

  @impl true
  def stream_completion(_messages, _model, _config, _tools), do: {:error, :not_implemented}

  @impl true
  def list_models(config) do
    # Re-use the Ollama provider's tag listing since the daemon is shared.
    Pincer.LLM.Providers.Ollama.list_models(config)
  end

  @impl true
  def transcribe_audio(_file_path, _model, _config), do: {:error, :not_implemented}

  @impl true
  def generate_embedding(text, model, config) do
    base_url = resolve_base_url(config)
    embed_url = "#{base_url}/api/embeddings"
    resolved_model = resolve_model(model, config)

    body = %{
      "model" => resolved_model,
      "prompt" => text
    }

    case Req.post(embed_url,
           json: body,
           receive_timeout: @timeout,
           connect_options: [timeout: @connect_timeout],
           retry: false
         ) do
      {:ok, %{status: 200, body: %{"embedding" => vector}}} when is_list(vector) ->
        {:ok, vector}

      {:ok, %{status: status, body: response_body}} ->
        error_msg = inspect(response_body)
        Logger.error("[OllamaEmbedding] HTTP error (#{status}): #{error_msg}")
        {:error, {:http_error, status, error_msg}}

      {:error, reason} ->
        Logger.error("[OllamaEmbedding] Request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # --- Private helpers ---

  defp resolve_base_url(config) do
    raw =
      config[:base_url] ||
        config[:ollama_base_url] ||
        System.get_env("OLLAMA_BASE_URL") ||
        @default_base_url

    String.trim_trailing(raw, "/")
  end

  defp resolve_model(model, config) do
    cond do
      is_binary(model) and model != "" ->
        model

      is_binary(config[:embedding_model]) and config[:embedding_model] != "" ->
        config[:embedding_model]

      true ->
        @default_model
    end
  end
end
