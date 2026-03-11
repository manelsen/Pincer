defmodule Pincer.LLM.Providers.MiniMax do
  @moduledoc """
  Adapter for MiniMax AI API.

  Particularities:
  - Endpoint: `https://api.minimax.chat/v1/text/chatcompletion_v2`.
  - Dual authentication: `Authorization: Bearer <API_KEY>` header and an additional
    `Authority` header carrying the Group ID.
  - API key via `MINIMAX_API_KEY`, Group ID via `MINIMAX_GROUP_ID`.
  - Otherwise follows the OpenAI-compatible chat completion schema.
  """
  @behaviour Pincer.LLM.Provider

  require Logger

  @base_url "https://api.minimax.chat/v1/text/chatcompletion_v2"

  @impl true
  def chat_completion(messages, model, config, tools) do
    config = normalize_config(config)
    Pincer.LLM.Providers.OpenAICompat.chat_completion(messages, model, config, tools)
  end

  @impl true
  def stream_completion(messages, model, config, tools) do
    config = normalize_config(config)
    Pincer.LLM.Providers.OpenAICompat.stream_completion(messages, model, config, tools)
  end

  @impl true
  def list_models(config) do
    config = normalize_config(config)
    api_key = config[:api_key]
    group_id = config[:minimax_group_id]

    if is_nil(api_key) or api_key == "" do
      {:ok,
       [
         "abab6.5s-chat",
         "abab6.5t-chat",
         "abab6-chat",
         "abab5.5s-chat",
         "abab5.5-chat"
       ]}
    else
      headers = build_auth_headers(api_key, group_id)
      models_url = "https://api.minimax.chat/v1/models"

      case Req.get(models_url,
             headers: headers,
             receive_timeout: 10_000,
             retry: :safe_transient
           ) do
        {:ok, %{status: 200, body: %{"data" => data}}} when is_list(data) ->
          models =
            data
            |> Enum.map(& &1["id"])
            |> Enum.reject(&is_nil/1)
            |> Enum.sort()

          {:ok, models}

        {:ok, response} ->
          Logger.warning("[MiniMax] Unexpected response listing models: #{response.status}")
          {:error, :unexpected_response}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl true
  def transcribe_audio(_file_path, _model, _config), do: {:error, :not_implemented}

  @impl true
  def generate_embedding(_text, _model, _config), do: {:error, :not_implemented}

  # --- Private helpers ---

  defp normalize_config(config) do
    api_key = config[:api_key] || System.get_env("MINIMAX_API_KEY") || ""
    group_id = config[:minimax_group_id] || System.get_env("MINIMAX_GROUP_ID") || ""

    auth_headers = build_auth_headers(api_key, group_id)
    existing_headers = config[:headers] || []

    config
    |> Map.put_new(:base_url, @base_url)
    |> Map.put(:api_key, api_key)
    |> Map.put(:minimax_group_id, group_id)
    # MiniMax requires both Authorization and Authority headers;
    # we inject them and clear :api_key so OpenAICompat does not double-set it.
    |> Map.put(:headers, existing_headers ++ auth_headers)
    # Use a dummy key so OpenAICompat does not bail for missing api_key,
    # while the real auth is carried in the headers above.
    |> Map.put(:api_key, api_key)
  end

  defp build_auth_headers(api_key, group_id) when is_binary(api_key) and is_binary(group_id) do
    headers = [{"authorization", "Bearer #{api_key}"}]

    if group_id != "" do
      [{"authority", group_id} | headers]
    else
      headers
    end
  end

  defp build_auth_headers(api_key, _group_id) when is_binary(api_key) do
    [{"authorization", "Bearer #{api_key}"}]
  end

  defp build_auth_headers(_api_key, _group_id), do: []
end
