defmodule Pincer.Adapters.Connectors.MCP.ConfigLoader do
  @moduledoc """
  Loads MCP server definitions from external JSON configuration files.

  This loader supports common `config.json` shapes used by Cursor and Claude
  Desktop, then normalizes them into Pincer's internal `"servers"` map format.
  """

  require Logger

  @type server_config :: map()
  @type servers_config :: %{optional(String.t()) => server_config()}

  @default_relative_paths [
    ".cursor/mcp.json",
    ".cursor/mcp_config.json",
    ".config/claude_desktop_config.json",
    ".config/Claude/claude_desktop_config.json",
    "Library/Application Support/Claude/claude_desktop_config.json"
  ]

  @doc """
  Discovers MCP servers from dynamic `config.json` sources.

  ## Options

  - `:paths` explicit list/string of JSON files to parse.
    When omitted, uses `:pincer, :mcp_dynamic_config_paths`, or default
    known paths under the user home directory.
  """
  @spec discover_servers(keyword()) :: servers_config()
  def discover_servers(opts \\ []) do
    opts
    |> candidate_paths()
    |> Enum.reduce(%{}, fn path, acc ->
      Map.merge(acc, load_servers_from_file(path))
    end)
  end

  @doc """
  Merges static project MCP config with dynamic `config.json` servers.

  Static servers take precedence on name conflicts.
  """
  @spec merge_static_and_dynamic(map(), keyword()) :: servers_config()
  def merge_static_and_dynamic(static_servers, opts \\ []) when is_map(static_servers) do
    dynamic_servers = discover_servers(opts)
    Map.merge(dynamic_servers, normalize_servers_map(static_servers))
  end

  defp candidate_paths(opts) do
    opts
    |> Keyword.get(:paths, configured_paths())
    |> normalize_paths()
  end

  defp configured_paths do
    case Application.get_env(:pincer, :mcp_dynamic_config_paths) do
      nil -> default_paths()
      value -> value
    end
  end

  defp default_paths do
    home = System.user_home!()
    Enum.map(@default_relative_paths, &Path.expand(&1, home))
  end

  defp normalize_paths(path) when is_binary(path) do
    [Path.expand(path)]
  end

  defp normalize_paths(paths) when is_list(paths) do
    paths
    |> Enum.reduce([], fn
      path, acc when is_binary(path) -> [Path.expand(path) | acc]
      _other, acc -> acc
    end)
    |> Enum.reverse()
    |> Enum.uniq()
  end

  defp normalize_paths(_), do: []

  defp load_servers_from_file(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} ->
        decode_servers(content, path)

      {:error, :enoent} ->
        %{}

      {:error, reason} ->
        Logger.warning("MCP dynamic config unreadable (#{path}): #{inspect(reason)}")
        %{}
    end
  end

  defp decode_servers(content, path) do
    case Jason.decode(content) do
      {:ok, %{} = decoded} ->
        decoded
        |> extract_server_map()
        |> normalize_servers_map()

      {:ok, _other} ->
        Logger.warning("MCP dynamic config ignored (invalid root object): #{path}")
        %{}

      {:error, reason} ->
        Logger.warning("MCP dynamic config ignored (invalid JSON at #{path}): #{inspect(reason)}")
        %{}
    end
  end

  defp extract_server_map(decoded) when is_map(decoded) do
    cond do
      is_map(decoded["mcpServers"]) ->
        decoded["mcpServers"]

      is_map(decoded[:mcpServers]) ->
        decoded[:mcpServers]

      is_map(get_in(decoded, ["mcp", "servers"])) ->
        get_in(decoded, ["mcp", "servers"])

      is_map(get_in(decoded, [:mcp, :servers])) ->
        get_in(decoded, [:mcp, :servers])

      true ->
        %{}
    end
  end

  defp normalize_servers_map(servers) when is_map(servers) do
    Enum.reduce(servers, %{}, fn
      {name, %{} = cfg}, acc ->
        normalized_cfg = stringify_keys(cfg)

        if disabled?(normalized_cfg) do
          acc
        else
          Map.put(acc, to_string(name), normalized_cfg)
        end

      _entry, acc ->
        acc
    end)
  end

  defp normalize_servers_map(_), do: %{}

  defp stringify_keys(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {k, v}, acc ->
      Map.put(acc, to_string(k), v)
    end)
  end

  defp disabled?(cfg) when is_map(cfg) do
    truthy?(Map.get(cfg, "disabled"))
  end

  defp truthy?(value) when value in [true, 1, "1", "true", "TRUE", "True"], do: true
  defp truthy?(_), do: false
end
