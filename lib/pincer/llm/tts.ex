defmodule Pincer.LLM.TTS do
  @moduledoc """
  OpenAI-compatible text-to-speech adapter implementing `Pincer.Ports.TTS`.

  Resolves provider configuration from `Pincer.LLM.CooldownRouting.provider_registry/0`
  and credentials from `Pincer.Core.AuthProfiles`, with `OPENAI_API_KEY` fallback
  when the requested provider is not explicitly configured in `:llm_providers`.
  """

  @behaviour Pincer.Ports.TTS

  alias Pincer.Core.AuthProfiles
  alias Pincer.LLM.CooldownRouting

  @default_url "https://api.openai.com/v1/audio/speech"
  @default_model "tts-1"
  @default_voice "alloy"
  @default_provider "openai"
  @default_timeout_ms 60_000

  @doc """
  Synthesizes `text` into binary audio using an OpenAI-compatible `/audio/speech` endpoint.

  ## Options

    * `:provider` - Provider key in `:llm_providers` (defaults to `:tts_provider` or `"openai"`).
    * `:voice` - Voice identifier (defaults to `"alloy"`).
    * `:model` - Override TTS model (defaults to provider `:tts_model` or `"tts-1"`).
    * `:auth_profile` - Optional preferred auth profile name.
    * `:env_fetcher` - Environment lookup function (defaults to `&System.get_env/1`).
    * `:http_post` - HTTP POST function (defaults to `&Req.post/2`).
    * `:receive_timeout` - Request timeout in ms (defaults to `60_000`).
  """
  @impl true
  @spec synthesize_speech(String.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def synthesize_speech(text, opts \\ []) when is_binary(text) and is_list(opts) do
    provider_key = Keyword.get(opts, :provider) || default_provider()
    voice = Keyword.get(opts, :voice) || @default_voice
    http_post = Keyword.get(opts, :http_post, &Req.post/2)
    receive_timeout = Keyword.get(opts, :receive_timeout, @default_timeout_ms)

    with {:ok, api_key, base_url, model} <- resolve_tts_config(provider_key, opts) do
      endpoint = tts_endpoint(base_url)
      body = %{"model" => model, "input" => text, "voice" => voice}

      case http_post.(endpoint,
             json: body,
             auth: {:bearer, api_key},
             receive_timeout: receive_timeout
           ) do
        {:ok, %{status: 200, body: audio}} when is_binary(audio) ->
          {:ok, audio}

        {:ok, %{status: status, body: resp_body}} ->
          {:error, "TTS request failed: #{status} — #{inspect(resp_body)}"}

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp resolve_tts_config(provider_key, opts) do
    registry = CooldownRouting.provider_registry()
    env_fetcher = Keyword.get(opts, :env_fetcher, &System.get_env/1)
    requested_profile = Keyword.get(opts, :auth_profile)
    requested_model = Keyword.get(opts, :model)

    case Map.get(registry, provider_key) do
      nil ->
        case normalize_key(env_fetcher.("OPENAI_API_KEY")) do
          nil ->
            {:error, "TTS provider '#{provider_key}' not configured and OPENAI_API_KEY not set"}

          key ->
            {:ok, key, @default_url, requested_model || @default_model}
        end

      config when is_map(config) ->
        with {:ok, selection} <-
               AuthProfiles.resolve(provider_key, config,
                 requested_profile: requested_profile,
                 env_fetcher: env_fetcher
               ) do
          resolved_config = selection.config
          api_key = selection.api_key || normalize_key(env_fetcher.("OPENAI_API_KEY")) || ""

          base_url =
            Map.get(resolved_config, :tts_base_url) ||
              Map.get(resolved_config, "tts_base_url") ||
              Map.get(resolved_config, :base_url) ||
              Map.get(resolved_config, "base_url") ||
              @default_url

          model =
            requested_model ||
              Map.get(resolved_config, :tts_model) ||
              Map.get(resolved_config, "tts_model") ||
              @default_model

          {:ok, api_key, base_url, model}
        end
    end
  end

  defp tts_endpoint(base_url) do
    trimmed = String.trim_trailing(base_url, "/")

    if String.ends_with?(trimmed, "/audio/speech") do
      trimmed
    else
      base = String.replace(trimmed, ~r{/chat/completions$}, "")
      "#{base}/audio/speech"
    end
  end

  defp normalize_key(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_key(_), do: nil

  defp default_provider do
    Application.get_env(:pincer, :tts_provider, @default_provider)
  end
end
