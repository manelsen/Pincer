defmodule Pincer.Channels.Matrix.API do
  @moduledoc """
  Behaviour for Matrix Client-Server API interactions.
  """

  @callback sync(
              homeserver_url :: String.t(),
              access_token :: String.t(),
              since :: String.t() | nil,
              timeout :: non_neg_integer()
            ) :: {:ok, map()} | {:error, any()}

  @callback send_message(
              homeserver_url :: String.t(),
              access_token :: String.t(),
              room_id :: String.t(),
              txn_id :: String.t(),
              body :: map()
            ) :: {:ok, map()} | {:error, any()}
end

defmodule Pincer.Channels.Matrix.API.Adapter do
  @moduledoc """
  Real implementation of the Matrix Client-Server API using Req.
  """

  @behaviour Pincer.Channels.Matrix.API

  @impl true
  def sync(homeserver_url, access_token, since, timeout) do
    params =
      [timeout: timeout, filter: Jason.encode!(%{room: %{timeline: %{limit: 50}}})]
      |> then(fn p -> if since, do: Keyword.put(p, :since, since), else: p end)

    url = "#{homeserver_url}/_matrix/client/v3/sync"

    case Req.get(url,
           params: params,
           headers: [{"authorization", "Bearer #{access_token}"}],
           receive_timeout: timeout + 10_000,
           connect_timeout: 10_000
         ) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def send_message(homeserver_url, access_token, room_id, txn_id, body) do
    encoded_room = URI.encode(room_id)

    url =
      "#{homeserver_url}/_matrix/client/v3/rooms/#{encoded_room}/send/m.room.message/#{txn_id}"

    case Req.put(url,
           json: body,
           headers: [{"authorization", "Bearer #{access_token}"}],
           receive_timeout: 30_000,
           connect_timeout: 10_000
         ) do
      {:ok, %{status: 200, body: resp}} -> {:ok, resp}
      {:ok, %{status: status, body: resp}} -> {:error, {status, resp}}
      {:error, reason} -> {:error, reason}
    end
  end
end
