defmodule Pincer.Channels.Slack.API do
  @moduledoc """
  Behavior for Slack API interactions.
  """
  @callback post(method :: String.t(), token :: String.t(), payload :: map()) :: {:ok, any()} | {:error, any()}
end

defmodule Pincer.Channels.Slack.API.Adapter do
  @moduledoc """
  Real implementation of Slack API using SlackElixir.
  """
  @behaviour Pincer.Channels.Slack.API

  @impl true
  def post(method, token, payload) do
    Elixir.Slack.API.post(method, token, payload)
  end
end
