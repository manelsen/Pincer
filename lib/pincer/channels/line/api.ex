defmodule Pincer.Channels.Line.API do
  @moduledoc """
  LINE Messaging API HTTP client.

  Provides functions for replying, pushing messages, and fetching user profiles
  via the LINE Messaging API. Uses `Req` for HTTP requests and reads the channel
  access token from the `LINE_CHANNEL_ACCESS_TOKEN` environment variable at call time.

  The `build_request/2` helper is public so that request construction can be
  tested without hitting the real API.
  """

  @reply_url "https://api.line.me/v2/bot/message/reply"
  @push_url "https://api.line.me/v2/bot/message/push"
  @profile_url "https://api.line.me/v2/bot/profile"

  @doc """
  Sends a reply message to a user, group, or room.

  ## Parameters

    - `reply_token` - Reply token received from a webhook event.
    - `messages` - List of message objects to send.

  ## Returns

    - `{:ok, map()}` on success (200).
    - `{:error, term()}` on failure.
  """
  @spec reply_message(String.t(), [map()]) :: {:ok, map()} | {:error, term()}
  def reply_message(reply_token, messages) do
    body = %{"replyToken" => reply_token, "messages" => messages}

    {@reply_url, opts} = build_request(:post, @reply_url, body)

    case Req.post(@reply_url, opts) do
      {:ok, %{status: 200}} -> {:ok, %{}}
      {:ok, %{status: status, body: resp}} -> {:error, {status, resp}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Sends a push message to a user, group, or room.

  ## Parameters

    - `to` - LINE user ID, group ID, or room ID.
    - `messages` - List of message objects to send.

  ## Returns

    - `{:ok, map()}` on success (200).
    - `{:error, term()}` on failure.
  """
  @spec push_message(String.t(), [map()]) :: {:ok, map()} | {:error, term()}
  def push_message(to, messages) do
    body = %{"to" => to, "messages" => messages}

    {@push_url, opts} = build_request(:post, @push_url, body)

    case Req.post(@push_url, opts) do
      {:ok, %{status: 200}} -> {:ok, %{}}
      {:ok, %{status: status, body: resp}} -> {:error, {status, resp}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Gets the profile of a LINE user.

  ## Parameters

    - `user_id` - LINE user ID.

  ## Returns

    - `{:ok, map()}` on success (200), with user profile fields.
    - `{:error, term()}` on failure.
  """
  @spec get_profile(String.t()) :: {:ok, map()} | {:error, term()}
  def get_profile(user_id) do
    url = "#{@profile_url}/#{user_id}"

    {url, opts} = build_request(:get, url, nil)

    case Req.get(url, opts) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Builds a `{url, opts}` tuple for a LINE API request.

  Public so that request construction can be tested in isolation without
  making real HTTP calls.

  ## Parameters

    - `:post` or `:get` - HTTP method (determines whether `:json` is included).
    - `url` - Full URL for the API endpoint.
    - `body` - Request body (map) for POST requests, or `nil` for GET.

  ## Returns

    - `{url, keyword()}` where the keyword list includes `:headers` and
      optionally `:json`.
  """
  @spec build_request(:post | :get, String.t(), map() | nil) :: {String.t(), keyword()}
  def build_request(:post, url, body) do
    token = fetch_token()

    opts = [
      json: body,
      headers: [{"Authorization", "Bearer #{token}"}]
    ]

    {url, opts}
  end

  def build_request(:get, url, nil) do
    token = fetch_token()

    opts = [
      headers: [{"Authorization", "Bearer #{token}"}]
    ]

    {url, opts}
  end

  defp fetch_token do
    System.get_env("LINE_CHANNEL_ACCESS_TOKEN") ||
      raise "LINE_CHANNEL_ACCESS_TOKEN environment variable is not set"
  end
end
