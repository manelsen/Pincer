defmodule Pincer.Adapters.Tools.Web do
  @moduledoc """
  Web interaction tool providing search and content fetching capabilities.

  This tool integrates with the Brave Search API for web search and includes
  a robust HTML content extractor for fetching and parsing web pages. It's
  designed for AI agent workflows where web information retrieval is needed.

  ## Security Features (SSRF Protection)

  The `fetch` action includes strict Server-Side Request Forgery (SSRF) protection:
  - **Scheme and credential validation**: only `http`/`https`, no URL userinfo.
  - **Address classification**: loopback, private, link-local, metadata, multicast,
    documentation, benchmark, and reserved IPv4/IPv6 ranges are blocked.
  - **DNS pinning**: the hostname is resolved once, every address is validated,
    and the request connects to the validated IP while keeping the original
    hostname for TLS SNI and the `Host` header.
  - **Redirect validation**: every redirect target is revalidated and repinned.
  - **Response cap**: HTML bodies above `:web_fetch_max_bytes` are rejected.

  ## Features

  - **Search**: Query the web using Brave Search API
  - **Fetch**: Download and extract readable text from URLs
  - **Smart Truncation**: Large content is truncated to 30,000 characters

  ## Actions

  | Action   | Description                          | Required Params |
  |----------|--------------------------------------|-----------------|
  | `search` | Search the web using Brave Search    | `query`         |
  | `fetch`  | Download and parse content from URL  | `url`           |

  ## Configuration

  Set the `BRAVE_API_KEY` environment variable for search functionality.
  """

  @behaviour Pincer.Ports.Tool
  alias Pincer.Adapters.Tools.WebFetchError
  alias Pincer.Adapters.Tools.WebVisibility
  alias Pincer.Utils.{BoundedBody, NetworkGuard}
  require Logger

  @user_agent "Pincer/0.1.0 (Mozilla/5.0 compliant)"
  @max_content_length 30_000
  @max_body_bytes Application.compile_env(:pincer, :web_fetch_max_bytes, 2_000_000)
  @connect_timeout 10_000
  @max_redirects 3

  @impl true
  def spec do
    [
      %{
        name: "web_search",
        description: "Search the web using Brave Search and return short textual results.",
        parameters: %{
          type: "object",
          properties: %{
            query: %{
              type: "string",
              description: "Search term."
            },
            count: %{
              type: "integer",
              description: "Number of results for search (1-10).",
              default: 5
            }
          },
          required: ["query"]
        }
      },
      %{
        name: "web_fetch",
        description:
          "Read a URL and extract readable text content. Prefer this for summarizing or inspecting a page when no interactive browser actions are needed.",
        parameters: %{
          type: "object",
          properties: %{
            url: %{
              type: "string",
              description: "URL to download."
            }
          },
          required: ["url"]
        }
      }
    ]
  end

  @impl true
  def execute(args) when is_map(args) do
    case Map.get(args, "tool_name") do
      "web_search" ->
        execute_search(args)

      "web_fetch" ->
        execute_fetch(args)

      _ ->
        execute_legacy(args)
    end
  end

  defp execute_legacy(%{"action" => "search"} = args), do: execute_search(args)
  defp execute_legacy(%{"action" => "fetch"} = args), do: execute_fetch(args)
  defp execute_legacy(_args), do: {:error, "Invalid arguments for web tool."}

  defp execute_search(%{"query" => query} = args) do
    count = Map.get(args, "count", 5)
    do_search(query, count)
  end

  defp execute_search(_args), do: {:error, "Missing required parameter: query"}

  defp execute_fetch(%{"url" => url}) do
    case NetworkGuard.safe_target(url) do
      {:ok, target} -> do_fetch(target, @max_redirects, http_client: http_client())
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute_fetch(_args), do: {:error, "Missing required parameter: url"}

  @doc """
  Validates a URL against the shared outbound network policy.
  """
  @spec validate_url(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def validate_url(url) when is_binary(url), do: NetworkGuard.validate_url(url)

  defp do_search(query, count) do
    api_key = System.get_env("BRAVE_API_KEY")

    if is_nil(api_key) or api_key == "" do
      {:error, "BRAVE_API_KEY not configured in environment."}
    else
      url = "https://api.search.brave.com/res/v1/web/search"

      case Req.get(url,
             params: [q: query, count: count],
             headers: [
               {"Accept", "application/json"},
               {"X-Subscription-Token", api_key}
             ],
             receive_timeout: 15_000,
             connect_options: [timeout: @connect_timeout]
           ) do
        {:ok, %{status: 200, body: body}} ->
          results = get_in(body, ["web", "results"]) || []

          if Enum.empty?(results) do
            {:ok, "No results found for: #{query}"}
          else
            output =
              results
              |> Enum.with_index(1)
              |> Enum.map_join("\n\n", fn {item, i} ->
                "#{i}. #{item["title"]}\nURL: #{item["url"]}\nSnippet: #{item["description"]}"
              end)

            {:ok, "Results for '#{query}':\n\n#{output}"}
          end

        {:ok, %{status: status}} ->
          {:error, "Brave API error (Status #{status})"}

        {:error, reason} ->
          {:error, "Web request failed: #{inspect(reason)}"}
      end
    end
  end

  defp do_fetch(target, redirects_remaining, opts) do
    Logger.info("[WEB] Fetching URL: #{target.url}")
    http_client = Keyword.fetch!(opts, :http_client)

    # Connect to the validated IP, but keep the original hostname for TLS SNI
    # and the Host header. This prevents a second DNS lookup from rebinding to
    # an internal address between validation and connection.
    case http_client.get(target.pinned_url,
           headers: [{"User-Agent", @user_agent}],
           redirect: false,
           decode_body: false,
           receive_timeout: 30_000,
           connect_options: [hostname: target.host, timeout: @connect_timeout],
           into: BoundedBody.callback(@max_body_bytes)
         ) do
      {:ok, %{status: status} = resp} when status in [301, 302, 307, 308] ->
        location = List.first(Req.Response.get_header(resp, "location"))

        cond do
          redirects_remaining <= 0 ->
            {:error, "Too many redirects"}

          is_nil(location) ->
            {:error, "Redirect with no location header"}

          true ->
            target =
              URI.merge(URI.parse(target.url), URI.parse(location))
              |> URI.to_string()

            case NetworkGuard.safe_target(target) do
              {:ok, valid_target} -> do_fetch(valid_target, redirects_remaining - 1, opts)
              {:error, reason} -> {:error, "Redirect to unsafe URL blocked: #{reason}"}
            end
        end

      {:ok, %Req.Response{status: 200, body: html} = resp} when is_binary(html) ->
        content_type = List.first(Req.Response.get_header(resp, "content-type")) || ""

        cond do
          byte_size(html) > @max_body_bytes ->
            {:error, "Response body exceeds #{@max_body_bytes} bytes"}

          String.contains?(content_type, "application/json") ->
            {:ok, html}

          true ->
            text = extract_text(html)
            final_text = truncate_text(text)
            {:ok, final_text}
        end

      {:ok, %{status: status}} ->
        {:error, "Error downloading URL (Status #{status})"}

      {:error, reason} ->
        {:error, WebFetchError.format(reason)}
    end
  end

  defp http_client do
    Application.get_env(:pincer, :web_http_client, Req)
  end

  defp truncate_text(text) do
    if String.length(text) > @max_content_length do
      String.slice(text, 0, @max_content_length) <> "... [TRUNCATED]"
    else
      text
    end
  end

  defp extract_text(html) do
    html
    |> WebVisibility.sanitize_html()
    |> remove_scripts_and_styles()
    |> convert_blocks_to_text()
    |> strip_tags()
    |> decode_and_normalize()
    |> WebVisibility.strip_invisible_unicode()
  end

  defp remove_scripts_and_styles(html) do
    html
    |> then(&Regex.replace(~r/<script[^>]*>.*?<\/script>/is, &1, ""))
    |> then(&Regex.replace(~r/<style[^>]*>.*?<\/style>/is, &1, ""))
  end

  defp convert_blocks_to_text(html) do
    html
    |> then(&Regex.replace(~r/<h([1-6])[^>]*>(.*?)<\/h\1>/is, &1, "\n\n# \\2\n"))
    |> then(&Regex.replace(~r/<p[^>]*>(.*?)<\/p>/is, &1, "\n\n\\1\n"))
    |> then(&Regex.replace(~r/<li[^>]*>(.*?)<\/li>/is, &1, "\n- \\1"))
  end

  defp strip_tags(html) do
    String.replace(html, ~r/<[^>]+>/, " ")
  end

  defp decode_and_normalize(text) do
    text
    |> Pincer.Adapters.Tools.Web.HtmlEntities.decode()
    |> String.replace(~r/[ \t]+/, " ")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end
end

defmodule Pincer.Adapters.Tools.Web.HtmlEntities do
  @moduledoc """
  Basic HTML entity decoder.
  """
  def decode(text) do
    text
    |> String.replace("&nbsp;", " ")
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
  end
end
