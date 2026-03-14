defmodule Pincer.Adapters.Tools.Web do
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

  @behaviour Pincer.Ports.Tool
  alias Pincer.Adapters.Tools.WebFetchError
  alias Pincer.Adapters.Tools.WebVisibility
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
    case validate_url(url) do
      {:ok, validated_url} -> do_fetch(validated_url, @max_redirects)
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute_fetch(_args), do: {:error, "Missing required parameter: url"}

  defp validate_url(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when not is_nil(scheme) and not is_nil(host) ->
        normalized_scheme = String.downcase(String.trim(scheme))
        normalized_host = normalize_host(host)

        cond do
          normalized_scheme not in @allowed_schemes ->
            {:error, "URL scheme '#{scheme}' not allowed"}

          is_nil(normalized_host) ->
            {:error, "Invalid URL format"}

          blocked_host?(normalized_host) ->
            {:error, "Access to internal hosts is not allowed"}

          true ->
            {:ok, url}
        end

      _ ->
        {:error, "Invalid URL format"}
    end
  end

  defp blocked_host?(host) do
    host in @blocked_hosts or
      match_private_ip?(host) or
      resolves_to_private_ip?(host)
  end

  defp normalize_host(host) when is_binary(host) do
    host
    |> String.trim()
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
    |> String.trim_trailing(".")
    |> String.downcase()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_host(_), do: nil

  defp match_private_ip?(ip) when is_binary(ip) do
    ip
    |> strip_ipv6_zone()
    |> String.to_charlist()
    |> :inet.parse_address()
    |> case do
      {:ok, addr} -> private_address?(addr)
      _ -> false
    end
  end

  defp match_private_ip?(_), do: false

  defp private_address?({_, _, _, _} = ipv4), do: private_ipv4?(ipv4)
  defp private_address?({_, _, _, _, _, _, _, _} = ipv6), do: private_ipv6?(ipv6)
  defp private_address?(_), do: false

  defp private_ipv4?(addr) do
    in_range?(addr, {0, 0, 0, 0}, 8) or
      in_range?(addr, {10, 0, 0, 0}, 8) or
      in_range?(addr, {100, 64, 0, 0}, 10) or
      in_range?(addr, {127, 0, 0, 0}, 8) or
      in_range?(addr, {169, 254, 0, 0}, 16) or
      in_range?(addr, {172, 16, 0, 0}, 12) or
      in_range?(addr, {192, 168, 0, 0}, 16)
  end

  defp private_ipv6?({0, 0, 0, 0, 0, 65_535, high, low}) do
    # IPv4-mapped IPv6 address (::ffff:a.b.c.d)
    ipv4 = {high >>> 8, high &&& 255, low >>> 8, low &&& 255}
    private_ipv4?(ipv4)
  end

  defp private_ipv6?({segment1, _, _, _, _, _, _, _} = ipv6) do
    ipv6 == {0, 0, 0, 0, 0, 0, 0, 1} or
      ipv6 == {0, 0, 0, 0, 0, 0, 0, 0} or
      (segment1 >= 0xFC00 and segment1 <= 0xFDFF) or
      (segment1 >= 0xFE80 and segment1 <= 0xFEBF)
  end

  defp resolves_to_private_ip?(host) do
    if match_private_ip?(host) do
      true
    else
      host
      |> resolve_host_addresses(:inet)
      |> Kernel.++(resolve_host_addresses(host, :inet6))
      |> Enum.any?(&private_address?/1)
    end
  end

  defp resolve_host_addresses(host, family) do
    case :inet.getaddrs(String.to_charlist(host), family) do
      {:ok, addresses} -> addresses
      _ -> []
    end
  end

  defp strip_ipv6_zone(host) do
    case String.split(host, "%", parts: 2) do
      [address, _zone] -> address
      [address] -> address
    end
  end

  defp in_range?({a, b, c, d}, base, prefix) do
    {base_a, base_b, base_c, base_d} = base

    # Calculate mask
    mask = bnot((1 <<< (32 - prefix)) - 1)

    # Pack IP into integer
    ip_int = a <<< 24 ||| b <<< 16 ||| c <<< 8 ||| d
    base_int = base_a <<< 24 ||| base_b <<< 16 ||| base_c <<< 8 ||| base_d

    (ip_int &&& mask) == (base_int &&& mask)
  end

  defp in_range?(_addr, _base, _prefix), do: false

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
        {:error, WebFetchError.format(reason)}
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
