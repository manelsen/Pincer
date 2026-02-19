defmodule Pincer.LLM.Client do
  @moduledoc """
  Cliente unificado para múltiplos provedores LLM (Opencode Zen, OpenRouter, Z.AI).
  Usa formato OpenAI-compatible para máxima compatibilidade.
  """
  require Logger

  @timeout 300_000
  @max_retries 5
  @initial_backoff 2000 # 2 segundos

  def chat_completion(messages, opts \\ []) do
    config = get_config()
    provider = Keyword.get(opts, :provider, config[:provider])
    model = Keyword.get(opts, :model, config[:default_model])
    tools = Keyword.get(opts, :tools, [])

    provider_config = case provider do
      :opencode_zen -> config[:opencode_zen]
      :openrouter -> config[:openrouter]
      :z_ai -> config[:z_ai]
      _ -> {:error, :unknown_provider}
    end

    case provider_config do
      {:error, _} -> {:error, :unknown_provider}
      conf -> do_request_with_retry(conf, messages, model, tools, @max_retries, @initial_backoff)
    end
  end

  defp get_config do
    llm_config = Application.get_env(:pincer, :llm, [])
    provider_key = Map.get(llm_config, "provider", "openrouter")

    provider =
      case provider_key do
        "opencode_zen" -> :opencode_zen
        "openrouter" -> :openrouter
        "z_ai" -> :z_ai
        _ -> :openrouter
      end

    opencode_key = System.get_env("OPENCODE_ZEN_API_KEY")
    openrouter_key = System.get_env("OPENROUTER_API_KEY")
    z_ai_key = System.get_env("Z_AI_API_KEY")

    opencode_config = Map.get(llm_config, "opencode_zen", %{})
    openrouter_config = Map.get(llm_config, "openrouter", %{})
    z_ai_config = Map.get(llm_config, "z_ai", %{})

    %{
      provider: provider,
      default_model: get_default_model(provider, opencode_config, openrouter_config, z_ai_config),
      opencode_zen: %{
        base_url: Map.get(opencode_config, "base_url"),
        api_key: opencode_key,
        default_model: Map.get(opencode_config, "default_model")
      },
      openrouter: %{
        base_url: Map.get(openrouter_config, "base_url"),
        api_key: openrouter_key,
        default_model: Map.get(openrouter_config, "default_model")
      },
      z_ai: %{
        base_url: Map.get(z_ai_config, "base_url"),
        api_key: z_ai_key,
        default_model: Map.get(z_ai_config, "default_model")
      }
    }
  end

  defp get_default_model(:opencode_zen, opencode, _, _), do: Map.get(opencode, "default_model")
  defp get_default_model(:openrouter, _, openrouter, _), do: Map.get(openrouter, "default_model")
  defp get_default_model(:z_ai, _, _, z_ai), do: Map.get(z_ai, "default_model")

  defp do_request_with_retry(provider_config, messages, model, tools, retries, delay) do
    case do_request(provider_config, messages, model, tools) do
      {:ok, result} -> {:ok, result}
      
      {:error, {:http_error, 429, _body}} when retries > 0 ->
        Logger.warning("Rate Limit (429). Tentando novamente em #{delay}ms... (#{retries} restantes)")
        Process.sleep(delay)
        do_request_with_retry(provider_config, messages, model, tools, retries - 1, delay * 2)

      error -> error
    end
  end

  defp do_request(provider_config, messages, model, tools) do
    api_key = provider_config[:api_key]
    base_url = provider_config[:base_url]

    if is_nil(api_key) or api_key == "" or is_nil(base_url) or base_url == "" do
      Logger.warning("Configuração incompleta para provedor. Usando modo MOCK.")
      simulate_response(messages)
    else
      if not String.contains?(base_url, "openrouter") and not Enum.empty?(tools) do
        Logger.info("Enviando requisição com TOOLS para provider não-OpenRouter: #{base_url}")
      end

      body = %{model: model, messages: messages}
      body = if Enum.empty?(tools), do: body, else: Map.put(body, :tools, tools)
      headers = get_headers(base_url)

      # Z.AI e outros suportam Bearer padrão em endpoints compatíveis
      case Req.post(base_url,
             json: body,
             auth: {:bearer, api_key},
             headers: headers,
             receive_timeout: @timeout,
             retry: :safe_transient
           ) do
        {:ok, response} -> handle_response(response)
        {:error, reason} -> 
          Logger.error("Erro na requisição LLM: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp get_headers(url) when is_binary(url) do
    cond do
      String.contains?(url, "openrouter") -> [{"HTTP-Referer", "https://github.com/Pincer/pincer"}, {"X-Title", "Pincer"}]
      true -> []
    end
  end
  defp get_headers(_), do: []

  defp handle_response(%Req.Response{status: 200, body: body}) do
    case body do
      %{"choices" => [%{"message" => message} | _]} -> {:ok, message}
      error_body when is_map(error_body) ->
        Logger.error("Formato de resposta inesperado: #{inspect(error_body)}")
        {:error, :unexpected_response_format}
      other ->
        Logger.error("Resposta não-JSON: #{inspect(other)}")
        {:error, :non_json_response}
    end
  end

  defp handle_response(%Req.Response{status: status, body: body}) do
    error_msg = if is_binary(body) and String.starts_with?(body, "<!") do
      "HTML Error Page (Início: #{String.slice(body, 0, 50)}...)"
    else
      inspect(body)
    end
    Logger.error("Erro HTTP (#{status}): #{error_msg}")
    {:error, {:http_error, status, error_msg}}
  end

  defp simulate_response(_messages) do
    {:ok, %{"role" => "assistant", "content" => "[MOCK] Olá!"}}
  end
end
