defmodule Pincer.Channels.DingTalk.API do
  @moduledoc """
  DingTalk HTTP API client.

  Provides functions for sending direct messages, group messages, and
  managing interactive cards via the DingTalk Open API. Uses `Req` for HTTP
  requests and `TokenCache` for OAuth2 access token management.

  The `build_request/3` helper is public so that request construction can be
  tested without hitting the real API.
  """

  alias Pincer.Channels.Shared.TokenCache

  @base_url "https://oapi.dingtalk.com"
  @token_url "#{@base_url}/v1.0/oauth2/accessToken"
  @dm_url "#{@base_url}/v1.0/robot/oToMessages/batchSend"
  @group_url "#{@base_url}/v1.0/robot/groupMessages/send"
  @card_url "#{@base_url}/v1.0/card/instances"

  @doc """
  Starts the TokenCache GenServer for DingTalk OAuth2 tokens.

  The fetch function posts client credentials to the DingTalk token endpoint
  and extracts `accessToken` and `expireIn` from the response.

  ## Options

    * `:name` -- registered name for the GenServer (defaults to `__MODULE__`)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    TokenCache.start_link(
      name: name,
      fetch_fn: fn ->
        client_id = System.get_env("DINGTALK_CLIENT_ID") || ""
        client_secret = System.get_env("DINGTALK_CLIENT_SECRET") || ""

        case Req.post(@token_url,
               json: %{
                 "client_id" => client_id,
                 "client_secret" => client_secret
               }
             ) do
          {:ok, %{status: 200, body: body}} ->
            token = Map.fetch!(body, "accessToken")
            expire_in = Map.fetch!(body, "expireIn")
            expires_at = System.system_time(:second) + expire_in
            {:ok, token, expires_at}

          {:ok, %{status: status, body: body}} ->
            {:error, {status, body}}

          {:error, reason} ->
            {:error, reason}
        end
      end
    )
  end

  @doc """
  Gets the current DingTalk access token from the TokenCache.

  Returns `{:ok, token}` or `{:error, reason}`.
  """
  @spec get_access_token() :: {:ok, String.t()} | {:error, term()}
  def get_access_token do
    TokenCache.get_token(__MODULE__)
  end

  @doc """
  Sends a direct message to one or more users.

  ## Parameters

    - `user_ids` - List of DingTalk user IDs.
    - `message` - Message content (JSON-encoded string).
    - `msg_key` - Message template key (e.g. `"sampleMarkdown"`).

  ## Returns

    - `{:ok, map()}` on success (200).
    - `{:error, term()}` on failure.
  """
  @spec send_dm([String.t()], String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def send_dm(user_ids, message, msg_key) do
    body = %{
      "userIds" => user_ids,
      "msgKey" => msg_key,
      "msgParam" => message
    }

    {@dm_url, opts} = build_request(:post, @dm_url, body)

    case Req.post(@dm_url, opts) do
      {:ok, %{status: 200}} -> {:ok, %{}}
      {:ok, %{status: status, body: resp}} -> {:error, {status, resp}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Sends a message to a group conversation.

  ## Parameters

    - `conversation_id` - DingTalk group conversation ID.
    - `message` - Message content (JSON-encoded string).
    - `msg_key` - Message template key.

  ## Returns

    - `{:ok, map()}` on success (200).
    - `{:error, term()}` on failure.
  """
  @spec send_group(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def send_group(conversation_id, message, msg_key) do
    body = %{
      "conversationId" => conversation_id,
      "msgKey" => msg_key,
      "msgParam" => message
    }

    {@group_url, opts} = build_request(:post, @group_url, body)

    case Req.post(@group_url, opts) do
      {:ok, %{status: 200}} -> {:ok, %{}}
      {:ok, %{status: status, body: resp}} -> {:error, {status, resp}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Creates an interactive card.

  ## Parameters

    - `content` - Card data map (passed as `cardParamMap`).
    - `config` - Card configuration map (must include `"cardTemplateId"`).

  ## Returns

    - `{:ok, map()}` on success (200).
    - `{:error, term()}` on failure.
  """
  @spec create_card(map(), map()) :: {:ok, map()} | {:error, term()}
  def create_card(content, config) do
    body = %{
      "cardData" => %{"cardParamMap" => content},
      "cardTemplateId" => config["cardTemplateId"]
    }

    {@card_url, opts} = build_request(:post, @card_url, body)

    case Req.post(@card_url, opts) do
      {:ok, %{status: 200, body: resp}} -> {:ok, resp}
      {:ok, %{status: status, body: resp}} -> {:error, {status, resp}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Updates an existing interactive card.

  ## Parameters

    - `card_instance_id` - The card instance ID to update.
    - `new_content` - New card data map (passed as `cardParamMap`).

  ## Returns

    - `{:ok, map()}` on success (200).
    - `{:error, term()}` on failure.
  """
  @spec update_card(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def update_card(card_instance_id, new_content) do
    url = "#{@card_url}/#{card_instance_id}"

    body = %{
      "cardData" => %{"cardParamMap" => new_content}
    }

    {url, opts} = build_request(:put, url, body)

    case Req.put(url, opts) do
      {:ok, %{status: 200, body: resp}} -> {:ok, resp}
      {:ok, %{status: status, body: resp}} -> {:error, {status, resp}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Builds a `{url, opts}` tuple for a DingTalk API request.

  Public so that request construction can be tested in isolation without
  making real HTTP calls.

  ## Parameters

    - `:post` or `:put` - HTTP method.
    - `url` - Full URL for the API endpoint.
    - `body` - Request body (map).

  ## Returns

    - `{url, keyword()}` where the keyword list includes `:headers` and `:json`.
  """
  @spec build_request(:post | :put, String.t(), map()) :: {String.t(), keyword()}
  def build_request(_method, url, body) do
    token = fetch_token()

    opts = [
      json: body,
      headers: [{"x-acs-dingtalk-access-token", token}]
    ]

    {url, opts}
  end

  @doc """
  Fetches the DingTalk access token from the environment.

  Reads `DINGTALK_ACCESS_TOKEN` at call time so that token rotation
  does not require a process restart.
  """
  @spec fetch_token() :: String.t()
  def fetch_token do
    System.get_env("DINGTALK_ACCESS_TOKEN") ||
      raise "DINGTALK_ACCESS_TOKEN environment variable is not set"
  end
end
