defmodule Pincer.Adapters.AttachmentFetcher do
  @moduledoc "Retrieves attachment bytes from Telegram file references and public HTTP(S) URLs."

  @behaviour PincerPorts.Attachments

  alias Pincer.Utils.{BoundedBody, NetworkGuard}

  @max_redirects 10
  @redirect_statuses [301, 302, 303, 307, 308]

  @impl true
  @doc """
  Fetches an attachment. The optional `:http_client` and `:telegram_token`
  options override the defaults for tests.
  """
  def fetch(reference, mode, opts \\ []) do
    http_client = Keyword.get(opts, :http_client, &Req.get/2)

    with {:ok, url, redirects} <- resolve(reference, mode, opts) do
      download(url, mode, http_client, redirects)
    end
  end

  defp resolve("telegram://file/" <> path, _mode, opts) do
    case Keyword.get_lazy(opts, :telegram_token, fn -> Application.get_env(:telegex, :token) end) do
      token when is_binary(token) and token != "" ->
        {:ok, "https://api.telegram.org/file/bot#{token}/#{path}", 0}

      _ ->
        {:error, :telegram_token_missing}
    end
  end

  defp resolve(_reference, :workspace, _opts), do: {:error, :unsupported_url}

  defp resolve(url, {:inline, _limit}, _opts) when is_binary(url),
    do: {:ok, url, @max_redirects}

  defp resolve(_reference, {:inline, _limit}, _opts), do: {:error, :invalid_attachment_url}

  defp download(url, :workspace, http_client, _redirects) do
    case http_client.(url, decode_body: false, redirect: false, receive_timeout: 300_000) do
      {:ok, %{status: 200, body: body}} when is_binary(body) -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:http_error, status}}
      {:ok, _response} -> {:error, :invalid_response}
      {:error, _reason} = error -> error
    end
  end

  defp download(url, {:inline, limit} = mode, http_client, redirects) do
    with {:ok, target} <- NetworkGuard.safe_target(url),
         {:ok, response} <-
           http_client.(target.pinned_url,
             headers: [{"Host", target.host_header}],
             decode_body: false,
             redirect: false,
             receive_timeout: 60_000,
             connect_options: Keyword.put(target.connect_options, :timeout, 10_000),
             into: BoundedBody.callback(limit)
           ) do
      case response do
        %{status: status} when status in @redirect_statuses and redirects > 0 ->
          with {:ok, next} <- redirect_url(url, response) do
            download(next, mode, http_client, redirects - 1)
          end

        %{status: 200, body: body} when is_binary(body) and byte_size(body) <= limit ->
          {:ok, body}

        %{status: 200, body: body} when is_binary(body) ->
          {:error, :attachment_too_large}

        %{status: status} ->
          {:error, "HTTP #{status}"}

        _ ->
          {:error, :invalid_response}
      end
    end
  end

  defp redirect_url(url, response) do
    case Req.Response.get_header(response, "location") do
      [location | _] ->
        with {:ok, uri} <- URI.new(location) do
          {:ok, url |> URI.merge(uri) |> URI.to_string()}
        end

      [] ->
        {:error, :missing_redirect_location}
    end
  end
end
