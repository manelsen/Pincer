defmodule Pincer.Channels.Feishu.API do
  @moduledoc """
  Feishu (Lark) HTTP API client.

  Provides functions for sending messages, replying to messages, and updating
  interactive cards via the Feishu Open API. Uses `Req` for HTTP requests and
  `TokenCache` for tenant access token management.

  The `build_request/3` and `build_request/4` helpers are public so that request
  construction can be tested without hitting the real API.

  The base URL defaults to `https://open.feishu.cn` (Feishu, China). Set
  `config :pincer, :feishu_base_url, "https://open.larksuite.com"` in config
  to use Lark (international).
  """

  alias Pincer.Channels.Shared.TokenCache

  @doc """
  Returns the configured Feishu/Lark base URL.

  Defaults to `"https://open.feishu.cn"`. Override via
  `Application.put_env(:pincer, :feishu_base_url, url)` for Lark (international).
  """
  @spec base_url() :: String.t()
  def base_url do
    Application.get_env(:pincer, :feishu_base_url, "https://open.feishu.cn")
  end

  @doc """
  Starts a TokenCache GenServer that fetches Feishu tenant access tokens.

  The `fetch_fn` POSTs to the Feishu auth endpoint using `FEISHU_APP_ID` and
  `FEISHU_APP_SECRET` environment variables. The cache is registered under the
  module name by default.

  ## Options

    * `:name` -- registered name for the GenServer (defaults to `__MODULE__`).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    TokenCache.start_link(
      name: name,
      fetch_fn: fn ->
        fetch_tenant_token()
      end
    )
  end

  @doc """
  Gets the current tenant access token from the TokenCache.

  Returns `{:ok, token}` or `{:error, reason}`.
  """
  @spec get_tenant_token() :: {:ok, String.t()} | {:error, term()}
  def get_tenant_token(cache_name \\ __MODULE__) do
    TokenCache.get_token(cache_name)
  end

  @doc """
  Sends a message to a Feishu user or chat.

  ## Parameters

    * `receive_id` -- Open ID of the recipient.
    * `content` -- JSON-encoded message content.
    * `msg_type` -- Message type (e.g. `"text"`, `"image"`, `"interactive"`).

  ## Returns

    * `{:ok, map()}` on success (200).
    * `{:error, term()}` on failure.
  """
  @spec send_message(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def send_message(receive_id, content, msg_type) do
    url = "#{base_url()}/im/v1/messages?receive_id_type=open_id"

    body = %{
      "receive_id" => receive_id,
      "msg_type" => msg_type,
      "content" => content
    }

    {_url, opts} = build_request(:post, url, body)

    case Req.post(url, opts) do
      {:ok, %{status: 200}} -> {:ok, %{}}
      {:ok, %{status: status, body: resp}} -> {:error, {status, resp}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Replies to a specific Feishu message.

  ## Parameters

    * `message_id` -- ID of the message to reply to.
    * `content` -- JSON-encoded message content.
    * `msg_type` -- Message type (e.g. `"text"`, `"image"`).

  ## Returns

    * `{:ok, map()}` on success (200).
    * `{:error, term()}` on failure.
  """
  @spec reply_message(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def reply_message(message_id, content, msg_type) do
    url = "#{base_url()}/im/v1/messages/#{message_id}/reply"

    body = %{
      "msg_type" => msg_type,
      "content" => content
    }

    {_url, opts} = build_request(:post, url, body)

    case Req.post(url, opts) do
      {:ok, %{status: 200}} -> {:ok, %{}}
      {:ok, %{status: status, body: resp}} -> {:error, {status, resp}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Updates an interactive card's content.

  ## Parameters

    * `card_token` -- Token identifying the card to update.
    * `new_content` -- Map with the new card content.

  ## Returns

    * `{:ok, map()}` on success (200).
    * `{:error, term()}` on failure.
  """
  @spec update_card(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def update_card(card_token, new_content) do
    url = "#{base_url()}/interactive/v1/card/update"

    body = %{
      "token" => card_token,
      "card" => new_content
    }

    {_url, opts} = build_request(:patch, url, body)

    case Req.patch(url, opts) do
      {:ok, %{status: 200}} -> {:ok, %{}}
      {:ok, %{status: status, body: resp}} -> {:error, {status, resp}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Builds a `{url, opts}` tuple for a Feishu API request.

  Public so that request construction can be tested in isolation without
  making real HTTP calls.

  ## Parameters

    * `method` -- `:post`, `:get`, or `:patch`.
    * `url` -- Full URL for the API endpoint.
    * `body` -- Request body (map), or `nil` for GET.
    * `cache_name` -- TokenCache process name (defaults to `__MODULE__`).

  ## Returns

    * `{url, keyword()}` where the keyword list includes `:headers` and
      optionally `:json`.
  """
  @spec build_request(:post | :get | :patch, String.t(), map() | nil, GenServer.name()) ::
          {String.t(), keyword()}
  def build_request(method, url, body, cache_name \\ __MODULE__)

  def build_request(:get, url, nil, cache_name) do
    token = fetch_cached_token(cache_name)

    opts = [
      headers: [{"Authorization", "Bearer #{token}"}]
    ]

    {url, opts}
  end

  def build_request(:patch, url, body, cache_name) do
    token = fetch_cached_token(cache_name)

    opts = [
      json: body,
      headers: [{"Authorization", "Bearer #{token}"}]
    ]

    {url, opts}
  end

  def build_request(:post, url, body, cache_name) do
    token = fetch_cached_token(cache_name)

    opts = [
      json: body,
      headers: [{"Authorization", "Bearer #{token}"}]
    ]

    {url, opts}
  end

  # -- Private helpers --

  defp fetch_cached_token(cache_name) do
    case TokenCache.get_token(cache_name) do
      {:ok, token} -> token
      {:error, reason} -> raise "Failed to get Feishu tenant token: #{inspect(reason)}"
    end
  end

  defp fetch_tenant_token do
    app_id = System.get_env("FEISHU_APP_ID") || raise "FEISHU_APP_ID is not set"
    app_secret = System.get_env("FEISHU_APP_SECRET") || raise "FEISHU_APP_SECRET is not set"

    url = "#{base_url()}/auth/v3/tenant_access_token/internal"

    body = %{
      "app_id" => app_id,
      "app_secret" => app_secret
    }

    case Req.post(url, json: body) do
      {:ok, %{status: 200, body: %{"tenant_access_token" => token, "expire" => expire}}} ->
        {:ok, token, System.system_time(:second) + expire}

      {:ok, %{status: status, body: resp}} ->
        {:error, {status, resp}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
