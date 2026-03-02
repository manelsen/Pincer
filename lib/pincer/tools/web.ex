defmodule Pincer.Tools.Web do
  @moduledoc """
  Web interaction tool providing search and content fetching capabilities.

  This tool integrates with the Brave Search API for web search and includes
  a robust HTML content extractor for fetching and parsing web pages. It's
  designed for AI agent workflows where web information retrieval is needed.

  ## Security Features (SSRF Protection)

  The `fetch` action includes strict Server-Side Request Forgery (SSRF) protection:
  - **Scheme Validation**: Only `http` and `https` are allowed.
  - **Host Blocking**:
    - Localhost (`127.0.0.1`, `localhost`, `0.0.0.0`, `::1`) is blocked.
    - Private IP ranges (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16) are blocked.
    - Cloud metadata services (`169.254.169.254`) are blocked.
  - **Redirect Validation**: Redirects are followed manually to validate the target URL.

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

  @behaviour Pincer.Tool
  require Logger
  import Bitwise

  @user_agent "Pincer/0.1.0 (Mozilla/5.0 compliant)"
  @max_content_length 30_000
  @max_redirects 3

  @blocked_hosts [
    "localhost",
    "127.0.0.1",
    "0.0.0.0",
    "::1",
    "169.254.169.254",
    "metadata.google.internal"
  ]
  @allowed_schemes ["http", "https"]

  @impl true
  def spec do
    %{
      name: "web",
      description: "Ferramentas web para busca e extração de conteúdo.",
      parameters: %{
        type: "object",
        properties: %{
          action: %{
            type: "string",
            enum: ["search", "fetch"],
            description: "Action to perform: 'search' to search on Brave, 'fetch' to read a URL."
          },
          query: %{
            type: "string",
            description: "Search term (required for action='search')."
          },
          url: %{
            type: "string",
            description: "URL to download (required for action='fetch')."
          },
          count: %{
            type: "integer",
            description: "Number of results for search (1-10).",
            default: 5
          }
        },
        required: ["action"]
      }
    }
  end

  @impl true
  def execute(%{"action" => "search", "query" => query} = args) do
    count = Map.get(args, "count", 5)
    do_search(query, count)
  end

  def execute(%{"action" => "fetch", "url" => url}) do
    case validate_url(url) do
      {:ok, validated_url} -> do_fetch(validated_url, @max_redirects)
      {:error, reason} -> {:error, reason}
    end
  end

  def execute(_), do: {:error, "Invalid arguments for web tool."}

  defp validate_url(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when not is_nil(scheme) and not is_nil(host) ->
        cond do
          scheme not in @allowed_schemes ->
            {:error, "URL scheme '#{scheme}' not allowed"}

          blocked_host?(host) ->
            {:error, "Access to internal hosts is not allowed"}

          true ->
            {:ok, url}
        end

      _ ->
        {:error, "Invalid URL format"}
    end
  end

  defp blocked_host?(host) do
    host = String.downcase(host)
    host in @blocked_hosts or match_private_ip?(host)
  end

  defp match_private_ip?(ip) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, addr} ->
        in_range?(addr, {10, 0, 0, 0}, 8) or
          in_range?(addr, {172, 16, 0, 0}, 12) or
          in_range?(addr, {192, 168, 0, 0}, 16) or
          in_range?(addr, {127, 0, 0, 0}, 8) or
          in_range?(addr, {169, 254, 0, 0}, 16)

      _ ->
        false
    end
  end

  defp in_range?(addr, base, prefix) do
    # Convert tuple to list for easier handling if needed, but tuple matching works for ipv4
    {a, b, c, d} = addr
    {base_a, base_b, base_c, base_d} = base

    # Calculate mask
    mask = bnot((1 <<< (32 - prefix)) - 1)

    # Pack IP into integer
    ip_int = a <<< 24 ||| b <<< 16 ||| c <<< 8 ||| d
    base_int = base_a <<< 24 ||| base_b <<< 16 ||| base_c <<< 8 ||| base_d

    (ip_int &&& mask) == (base_int &&& mask)
  end

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
             ]
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

  defp do_fetch(url, redirects_remaining) do
    Logger.info("[WEB] Fetching URL: #{url}")

    # Use redirect: false to manually handle redirects for validation
    case Req.get(url,
           headers: [{"User-Agent", @user_agent}],
           redirect: false,
           receive_timeout: 30_000
         ) do
      {:ok, %{status: status} = resp} when status in [301, 302, 307, 308] ->
        location = List.first(Req.Response.get_header(resp, "location"))

        cond do
          redirects_remaining <= 0 ->
            {:error, "Too many redirects"}

          is_nil(location) ->
            {:error, "Redirect with no location header"}

          true ->
            # Handle relative redirects
            target = URI.merge(URI.parse(url), URI.parse(location)) |> URI.to_string()

            case validate_url(target) do
              {:ok, valid_target} -> do_fetch(valid_target, redirects_remaining - 1)
              {:error, reason} -> {:error, "Redirect to unsafe URL blocked: #{reason}"}
            end
        end

      {:ok, %Req.Response{status: 200, body: html} = resp} ->
        content_type = List.first(Req.Response.get_header(resp, "content-type")) || ""

        if String.contains?(content_type, "application/json") do
          {:ok, html}
        else
          text = extract_text(html)
          final_text = truncate_text(text)
          {:ok, final_text}
        end

      {:ok, %{status: status}} ->
        {:error, "Error downloading URL (Status #{status})"}

      {:error, reason} ->
        {:error, "Fetch failed: #{inspect(reason)}"}
    end
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
    |> remove_scripts_and_styles()
    |> convert_blocks_to_text()
    |> strip_tags()
    |> decode_and_normalize()
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
    |> HtmlEntities.decode()
    |> String.replace(~r/[ \t]+/, " ")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end
end

defmodule HtmlEntities do
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
