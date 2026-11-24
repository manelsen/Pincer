defmodule Pincer.Utils.NetworkGuard do
  @moduledoc """
  Outbound URL policy for untrusted network destinations.

  The guard validates schemes, rejects credentials in URLs, blocks loopback,
  private, link-local, documentation, multicast, and reserved address ranges
  (including IPv4-mapped IPv6), resolves hostnames, and returns a pinned
  connection target. Callers that support pinning should connect to
  `target.pinned_url` while keeping the original hostname for TLS SNI and the
  `Host` header through `target.connect_options`.

  Pinning closes the DNS-rebinding window between validation and connection.
  Callers that cannot pin (for example a browser sidecar) must still use
  `validate_url/1` and revalidate every redirect.
  """

  import Bitwise

  @allowed_schemes ~w(http https)
  @blocked_hosts ~w(localhost localhost.localdomain ip6-localhost ip6-loopback metadata metadata.google.internal instance-data)
  @blocked_suffixes ~w(.localhost .local .internal .home.arpa)

  @type address :: :inet.ip_address()
  @type target :: %{
          url: String.t(),
          pinned_url: String.t(),
          scheme: String.t(),
          host: String.t(),
          port: :inet.port_number(),
          address: address(),
          connect_options: keyword()
        }

  @doc "Validates a URL and resolves it without exposing the pinned target."
  @spec validate_url(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def validate_url(url) when is_binary(url) do
    with {:ok, target} <- safe_target(url) do
      {:ok, target.url}
    end
  end

  @doc """
  Validates and resolves a URL, returning a connection target pinned to one
  validated address.
  """
  @spec safe_target(String.t()) :: {:ok, target()} | {:error, String.t()}
  def safe_target(url) when is_binary(url) do
    with {:ok, uri} <- parse_uri(url),
         :ok <- reject_userinfo(uri),
         {:ok, scheme} <- validate_scheme(uri),
         {:ok, host} <- normalize_host(uri.host),
         :ok <- validate_hostname(host),
         {:ok, addresses} <- resolve(host),
         :ok <- reject_private_addresses(addresses),
         {:ok, address} <- preferred_address(addresses),
         {:ok, pinned_url} <- pin_url(uri, scheme, address) do
      {:ok,
       %{
         url: url,
         pinned_url: pinned_url,
         scheme: scheme,
         host: host,
         port: uri.port || default_port(scheme),
         address: address,
         connect_options: [hostname: host]
       }}
    end
  end

  def safe_target(_url), do: {:error, "Invalid URL format"}

  @doc "Resolves a hostname to its A and AAAA addresses."
  @spec resolve(String.t()) :: {:ok, [address()]} | {:error, String.t()}
  def resolve(host) when is_binary(host) do
    case parse_ip(host) do
      {:ok, address} ->
        {:ok, [address]}

      _other ->
        resolver().(host)
        |> normalize_resolution()
    end
  end

  @doc "Returns true only for globally routable unicast addresses."
  @spec public_address?(term()) :: boolean()
  def public_address?(address), do: not private_address?(address)

  defp parse_uri(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} = uri when is_binary(scheme) and is_binary(host) ->
        {:ok, uri}

      _ ->
        {:error, "Invalid URL format"}
    end
  rescue
    _ -> {:error, "Invalid URL format"}
  end

  defp reject_userinfo(%URI{userinfo: nil}), do: :ok
  defp reject_userinfo(_uri), do: {:error, "URL credentials are not allowed"}

  defp validate_scheme(%URI{scheme: scheme}) do
    normalized = scheme |> String.trim() |> String.downcase()

    if normalized in @allowed_schemes do
      {:ok, normalized}
    else
      {:error, "URL scheme '#{scheme}' not allowed"}
    end
  end

  defp normalize_host(host) when is_binary(host) do
    normalized =
      host
      |> String.trim()
      |> String.trim_leading("[")
      |> String.trim_trailing("]")
      |> String.trim_trailing(".")
      |> String.downcase()

    if normalized == "", do: {:error, "Invalid URL format"}, else: {:ok, normalized}
  end

  defp validate_hostname(host) do
    cond do
      host in @blocked_hosts ->
        {:error, "Access to internal hosts is not allowed"}

      Enum.any?(@blocked_suffixes, &String.ends_with?(host, &1)) ->
        {:error, "Access to internal hosts is not allowed"}

      true ->
        :ok
    end
  end

  defp resolver do
    Application.get_env(:pincer, :network_guard_resolver, &system_resolve/1)
  end

  defp system_resolve(host) do
    charlist = String.to_charlist(host)

    ipv4 =
      case :inet.getaddrs(charlist, :inet) do
        {:ok, addresses} -> addresses
        _ -> []
      end

    ipv6 =
      case :inet.getaddrs(charlist, :inet6) do
        {:ok, addresses} -> addresses
        _ -> []
      end

    case ipv4 ++ ipv6 do
      [] -> {:error, "Could not resolve host"}
      addresses -> {:ok, addresses}
    end
  rescue
    _ -> {:error, "Could not resolve host"}
  end

  defp normalize_resolution({:ok, addresses}) when is_list(addresses) and addresses != [],
    do: {:ok, addresses}

  defp normalize_resolution({:ok, _empty}), do: {:error, "Could not resolve host"}
  defp normalize_resolution({:error, _reason}), do: {:error, "Could not resolve host"}
  defp normalize_resolution(_other), do: {:error, "Could not resolve host"}

  defp reject_private_addresses(addresses) do
    if Enum.any?(addresses, &private_address?/1) do
      {:error, "Access to internal hosts is not allowed"}
    else
      :ok
    end
  end

  defp preferred_address(addresses) do
    address =
      Enum.find(addresses, &match?({_, _, _, _}, &1)) ||
        Enum.find(addresses, &match?({_, _, _, _, _, _, _, _}, &1))

    if address, do: {:ok, address}, else: {:error, "Could not resolve host"}
  end

  defp default_port("http"), do: 80
  defp default_port("https"), do: 443

  defp pin_url(uri, scheme, address) do
    host = address |> :inet.ntoa() |> to_string()
    authority = if tuple_size(address) == 8, do: "[#{host}]", else: host

    port =
      if uri.port && uri.port != default_port(scheme), do: ":#{uri.port}", else: ""

    path = if uri.path in [nil, ""], do: "/", else: uri.path
    query = if uri.query, do: "?" <> uri.query, else: ""
    {:ok, "#{scheme}://#{authority}#{port}#{path}#{query}"}
  end

  defp parse_ip(host) do
    host
    |> strip_ipv6_zone()
    |> String.to_charlist()
    |> :inet.parse_address()
  rescue
    _ -> :error
  end

  defp strip_ipv6_zone(host) do
    case String.split(host, "%", parts: 2) do
      [address, _zone] -> address
      [address] -> address
    end
  end

  defp private_address?({_, _, _, _} = ipv4), do: private_ipv4?(ipv4)
  defp private_address?({_, _, _, _, _, _, _, _} = ipv6), do: private_ipv6?(ipv6)
  defp private_address?(_), do: true

  defp private_ipv4?(addr) do
    in_range?(addr, {0, 0, 0, 0}, 8) or
      in_range?(addr, {10, 0, 0, 0}, 8) or
      in_range?(addr, {100, 64, 0, 0}, 10) or
      in_range?(addr, {127, 0, 0, 0}, 8) or
      in_range?(addr, {169, 254, 0, 0}, 16) or
      in_range?(addr, {172, 16, 0, 0}, 12) or
      in_range?(addr, {192, 0, 0, 0}, 24) or
      in_range?(addr, {192, 0, 2, 0}, 24) or
      in_range?(addr, {192, 88, 99, 0}, 24) or
      in_range?(addr, {192, 168, 0, 0}, 16) or
      in_range?(addr, {198, 18, 0, 0}, 15) or
      in_range?(addr, {198, 51, 100, 0}, 24) or
      in_range?(addr, {203, 0, 113, 0}, 24) or
      in_range?(addr, {224, 0, 0, 0}, 4) or
      in_range?(addr, {240, 0, 0, 0}, 4)
  end

  defp private_ipv6?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  defp private_ipv6?({0, 0, 0, 0, 0, 0, 0, 1}), do: true

  defp private_ipv6?({0, 0, 0, 0, 0, 0xFFFF, high, low}),
    do: private_ipv4?({high >>> 8, high &&& 255, low >>> 8, low &&& 255})

  defp private_ipv6?({0, 0, 0, 0, 0, 0, high, low}),
    do: private_ipv4?({high >>> 8, high &&& 255, low >>> 8, low &&& 255})

  defp private_ipv6?({0x0064, 0xFF9B, 0, 0, 0, 0, _, _}), do: true
  defp private_ipv6?({0x0100, 0, 0, 0, 0, 0, 0, 0}), do: true
  defp private_ipv6?({0x2001, 0x0DB8, _, _, _, _, _, _}), do: true
  defp private_ipv6?({0x2001, 0x0002, _, _, _, _, _, _}), do: true

  defp private_ipv6?({segment1, _, _, _, _, _, _, _}) do
    (segment1 >= 0xFC00 and segment1 <= 0xFDFF) or
      (segment1 >= 0xFE80 and segment1 <= 0xFEBF) or
      (segment1 >= 0xFF00 and segment1 <= 0xFFFF)
  end

  defp in_range?({a, b, c, d}, {base_a, base_b, base_c, base_d}, prefix) do
    mask = bnot((1 <<< (32 - prefix)) - 1)
    ip_int = a <<< 24 ||| b <<< 16 ||| c <<< 8 ||| d
    base_int = base_a <<< 24 ||| base_b <<< 16 ||| base_c <<< 8 ||| base_d
    (ip_int &&& mask) == (base_int &&& mask)
  end

  defp in_range?(_addr, _base, _prefix), do: false
end
