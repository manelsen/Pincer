defmodule Pincer.Adapters.Tools.SessionSearch do
  @moduledoc """
  Searches and reads persisted session transcripts.

  This tool exposes the storage search surface without any filesystem access:
  it only calls `Pincer.Ports.Storage`, so it cannot escape `AgentPaths`.

  Actions:

    * `"discover"` — ranks sessions by hit count for a query.
    * `"search"` — returns individual message hits with role and snippet.
    * `"read"` — pages through a session transcript (`get_messages/1` returns
      the whole session, so paging happens here).

  Requests are validated strictly: unknown actions and missing/mistyped
  arguments return `{:error, reason}` before storage is touched.
  """

  @behaviour Pincer.Ports.Tool

  alias Pincer.Ports.Storage

  @discover_default 5
  @discover_max 20
  @search_default 10
  @search_max 50
  @read_default 20
  @read_max 100

  @impl true
  def spec do
    %{
      name: "session_search",
      description:
        "Search and read persisted session transcripts. Use \"discover\" to find " <>
          "sessions matching a query, \"search\" to find individual messages, and " <>
          "\"read\" to page through one session by id.",
      parameters: %{
        type: "object",
        properties: %{
          action: %{
            type: "string",
            enum: ["discover", "search", "read"],
            description: "Operation to perform."
          },
          query: %{
            type: "string",
            description: "Search query (required for discover and search)."
          },
          limit: %{
            type: "integer",
            description:
              "Maximum results: discover defaults to 5 (max 20), search to 10 (max 50), " <>
                "read to 20 (max 100)."
          },
          session_id: %{
            type: "string",
            description: "Session to read (required for read)."
          },
          offset: %{
            type: "integer",
            description:
              "Zero-based message offset for read. Defaults to the tail of the session."
          }
        },
        required: ["action"]
      }
    }
  end

  @impl true
  def execute(args), do: execute(args, %{})

  @impl true
  def execute(args, context) do
    storage = Map.get(context, :storage, Storage)

    case Map.get(args, "action") do
      "discover" -> discover(args, storage)
      "search" -> search(args, storage)
      "read" -> read(args, storage)
      nil -> {:error, "Missing required argument: action (discover, search, or read)"}
      other -> {:error, "Unknown action: #{inspect(other)}. Expected discover, search, or read."}
    end
  end

  defp discover(args, storage) do
    with {:ok, query} <- query_arg(args),
         {:ok, limit} <- limit_arg(args, @discover_default, @discover_max) do
      case storage.search_sessions(query, limit) do
        {:ok, sessions} when is_list(sessions) ->
          {:ok, render_sessions(query, limit, sessions)}

        {:error, reason} ->
          {:error, "Session search failed: #{inspect(reason)}"}

        other ->
          {:error, "Session search failed: #{inspect(other)}"}
      end
    end
  end

  defp search(args, storage) do
    with {:ok, query} <- query_arg(args),
         {:ok, limit} <- limit_arg(args, @search_default, @search_max) do
      case storage.search_messages(query, limit) do
        {:ok, hits} when is_list(hits) ->
          {:ok, render_hits(query, limit, hits)}

        {:error, reason} ->
          {:error, "Message search failed: #{inspect(reason)}"}

        other ->
          {:error, "Message search failed: #{inspect(other)}"}
      end
    end
  end

  defp read(args, storage) do
    with {:ok, session_id} <- session_id_arg(args),
         {:ok, limit} <- limit_arg(args, @read_default, @read_max),
         {:ok, offset} <- offset_arg(args) do
      case storage.get_messages(session_id) do
        messages when is_list(messages) ->
          {:ok, render_read(session_id, messages, offset, limit)}

        other ->
          {:error, "Failed to load session #{session_id}: #{inspect(other)}"}
      end
    end
  end

  defp render_sessions(_query, _limit, []), do: "No sessions found for query."

  defp render_sessions(query, limit, sessions) do
    body =
      sessions
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {session, rank} ->
        "##{rank} session #{field(session, :session_id)} — " <>
          "#{field(session, :hit_count)} hit(s)\n" <>
          "   preview: #{one_line(field(session, :preview))}"
      end)

    "Session search results for #{inspect(query)} (limit #{limit}):\n\n" <> body
  end

  defp render_hits(_query, _limit, []), do: "No messages found for query."

  defp render_hits(query, limit, hits) do
    body =
      hits
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {hit, rank} ->
        "##{rank} session #{session_id_of(hit)} [#{field(hit, :role)}] " <>
          one_line(field(hit, :content))
      end)

    "Message search results for #{inspect(query)} (limit #{limit}):\n\n" <> body
  end

  defp render_read(session_id, [], _offset, _limit), do: "Session #{session_id} has no messages."

  defp render_read(session_id, messages, offset_or_tail, limit) do
    total = length(messages)
    offset = resolve_offset(offset_or_tail, total, limit)
    slice = Enum.slice(messages, offset, limit)

    case slice do
      [] ->
        "Session #{session_id}: no messages at offset #{offset} (total #{total})."

      _ ->
        first = offset + 1
        last = offset + length(slice)

        next_offset =
          if last < total, do: last, else: nil

        lines =
          slice
          |> Enum.with_index(first)
          |> Enum.map_join("\n", fn {message, index} ->
            "[#{index}] #{field(message, :role)}: #{one_line(field(message, :content))}"
          end)

        "Session #{session_id}: showing #{first}-#{last} of #{total}\n" <>
          lines <> "\nnext_offset: #{next_offset || "none"}"
    end
  end

  defp resolve_offset(:tail, total, limit), do: max(total - limit, 0)
  defp resolve_offset(offset, _total, _limit), do: offset

  defp query_arg(args) do
    case Map.get(args, "query") do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, "Missing required argument: query"}
          trimmed -> {:ok, trimmed}
        end

      nil ->
        {:error, "Missing required argument: query"}

      _other ->
        {:error, "Invalid argument: query must be a non-empty string"}
    end
  end

  defp limit_arg(args, default, max) do
    case Map.get(args, "limit") do
      nil -> {:ok, default}
      limit when is_integer(limit) and limit > 0 -> {:ok, min(limit, max)}
      _other -> {:error, "Invalid argument: limit must be a positive integer"}
    end
  end

  defp offset_arg(args) do
    case Map.get(args, "offset") do
      nil -> {:ok, :tail}
      offset when is_integer(offset) and offset >= 0 -> {:ok, offset}
      _other -> {:error, "Invalid argument: offset must be a non-negative integer"}
    end
  end

  defp session_id_arg(args) do
    case Map.get(args, "session_id") do
      session_id when is_binary(session_id) ->
        case String.trim(session_id) do
          "" -> {:error, "Missing required argument: session_id"}
          trimmed -> {:ok, trimmed}
        end

      nil ->
        {:error, "Missing required argument: session_id"}

      _other ->
        {:error, "Invalid argument: session_id must be a non-empty string"}
    end
  end

  defp session_id_of(hit) do
    Map.get(hit, :session_id) || Map.get(hit, "session_id") ||
      extract_session_id(Map.get(hit, :source) || Map.get(hit, "source"))
  end

  defp extract_session_id("session:" <> rest) do
    rest |> String.split(":", parts: 3) |> hd()
  end

  defp extract_session_id(_source), do: "unknown"

  defp field(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp one_line(nil), do: ""
  defp one_line(value) when is_binary(value), do: value |> String.split() |> Enum.join(" ")
  defp one_line(value), do: value |> to_string() |> one_line()
end
