defmodule Pincer.LLM.Capabilities do
  @moduledoc """
  Non-chat LLM capabilities: audio transcription and text embeddings.

  Resolves provider configuration and auth profiles, normalizes adapter errors
  via `Pincer.LLM.RetryEngine.normalize_reason/1`, and handles OpenRouter's
  `baai/bge-m3` -> `baai/bge-large-en-v1.5` embedding fallback.
  """

  require Logger

  alias Pincer.Core.AuthProfiles
  alias Pincer.LLM.{CooldownRouting, RetryEngine}

  @default_transcription_provider "groq_whisper"
  @default_embedding_provider "openrouter"
  @openrouter_default_embedding_model "baai/bge-m3"
  @openrouter_fallback_embedding_model "baai/bge-large-en-v1.5"

  @doc """
  Transcribes a local audio file using the configured transcription provider
  (defaults to `"groq_whisper"`).
  """
  @spec transcribe_audio(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def transcribe_audio(file_path, opts \\ []) do
    with {:ok, _provider_id, config, config_with_auth} <-
           resolve_provider_auth(opts, @default_transcription_provider) do
      model = Keyword.get(opts, :model, config[:default_model])

      apply(config[:adapter], :transcribe_audio, [file_path, model, config_with_auth])
      |> normalize_error_result()
    end
  end

  @doc """
  Generates an embedding vector for `text` using the configured embedding
  provider (defaults to `"openrouter"` with `baai/bge-m3` and router-miss fallback).
  """
  @spec generate_embedding(String.t(), keyword()) :: {:ok, [float()]} | {:error, term()}
  def generate_embedding(text, opts \\ []) do
    with {:ok, provider_id, config, config_with_auth} <-
           resolve_provider_auth(opts, @default_embedding_provider) do
      model = resolve_embedding_model(provider_id, config, opts)

      generate_embedding_with_fallback(
        config[:adapter],
        text,
        model,
        config_with_auth,
        provider_id,
        opts
      )
    end
  end

  defp resolve_provider_auth(opts, default_provider) do
    registry = CooldownRouting.provider_registry()
    provider_id = Keyword.get(opts, :provider, default_provider)

    case Map.get(registry, provider_id) do
      nil ->
        {:error, :unknown_provider}

      config ->
        requested_profile = Keyword.get(opts, :auth_profile)

        case AuthProfiles.resolve(provider_id, config, requested_profile: requested_profile) do
          {:ok, auth_selection} ->
            {:ok, provider_id, config, auth_selection.config}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp resolve_embedding_model(provider_id, config, opts) do
    Keyword.get(opts, :model) ||
      config[:embedding_model] ||
      if(provider_id == @default_embedding_provider,
        do: @openrouter_default_embedding_model,
        else: config[:default_model]
      )
  end

  defp generate_embedding_with_fallback(adapter, text, model, config, provider_id, opts) do
    case apply(adapter, :generate_embedding, [text, model, config])
         |> normalize_error_result() do
      {:error, reason} = error ->
        maybe_retry_embedding(adapter, text, model, config, provider_id, opts, reason, error)

      other ->
        other
    end
  end

  defp maybe_retry_embedding(adapter, text, model, config, provider_id, opts, reason, error) do
    with true <- provider_id == @default_embedding_provider,
         false <- Keyword.has_key?(opts, :model),
         true <- retryable_openrouter_embedding_error?(reason),
         fallback_model when is_binary(fallback_model) <- fallback_embedding_model(model, config) do
      Logger.warning(
        "[LLM] Embedding model #{model} failed via #{provider_id} router. Retrying with #{fallback_model}."
      )

      apply(adapter, :generate_embedding, [text, fallback_model, config])
      |> normalize_error_result()
    else
      _ -> error
    end
  end

  defp retryable_openrouter_embedding_error?(
         {:http_error, status, %{"error" => %{"message" => message}}}
       )
       when status in [200, 404] and is_binary(message) do
    String.contains?(message, "No successful provider responses")
  end

  defp retryable_openrouter_embedding_error?(_), do: false

  defp fallback_embedding_model(@openrouter_default_embedding_model, config) do
    config[:embedding_fallback_model] || @openrouter_fallback_embedding_model
  end

  defp fallback_embedding_model(_model, config), do: config[:embedding_fallback_model]

  defp normalize_error_result({:error, reason}),
    do: {:error, RetryEngine.normalize_reason(reason)}

  defp normalize_error_result(other), do: other
end
