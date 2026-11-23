defmodule Pincer.Storage.MemoryHelpers do
  @moduledoc """
  Pure helpers shared by the SQLite storage adapter.

  These functions never touch a database. They operate on the JSON `data`
  payload of a memory node (or a plain node map) and are used by both adapters
  so that scoring, metadata construction, filtering and citation formatting
  cannot drift between backends.
  """

  alias Pincer.Core.MemoryTypes

  @doc """
  Builds the JSON `data` payload stored for an indexed document.

  Nil-valued options are omitted so stored documents stay compact.
  """
  @spec build_memory_metadata(String.t(), String.t(), term(), keyword()) :: map()
  def build_memory_metadata(path, content, memory_type, opts) do
    %{
      "path" => path,
      "content" => content,
      "memory_type" => MemoryTypes.normalize(memory_type),
      "importance" => normalize_importance(Keyword.get(opts, :importance, 5)),
      "access_count" => Keyword.get(opts, :access_count, 0),
      "last_accessed_at" => Keyword.get(opts, :last_accessed_at),
      "forgotten_at" => Keyword.get(opts, :forgotten_at),
      "session_id" => Keyword.get(opts, :session_id),
      "workspace_root" => Keyword.get(opts, :workspace_root),
      "line_start" => Keyword.get(opts, :line_start),
      "line_end" => Keyword.get(opts, :line_end)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  @doc "Clamps an importance value into the 0..10 range, defaulting to 5."
  @spec normalize_importance(term()) :: integer()
  def normalize_importance(value) when is_integer(value), do: min(10, max(0, value))
  def normalize_importance(_), do: 5

  @doc "True when the document matches the `:memory_type` and `:session_id` options."
  @spec document_matches_opts?(map(), keyword()) :: boolean()
  def document_matches_opts?(data, opts) do
    type_match? =
      case Keyword.get(opts, :memory_type) do
        nil -> true
        type -> data["memory_type"] == MemoryTypes.normalize(type)
      end

    session_match? =
      case Keyword.get(opts, :session_id) do
        nil -> true
        session_id -> data["session_id"] == session_id
      end

    type_match? and session_match?
  end

  @doc "True when the document's workspace matches the `:workspace_root` option."
  @spec match_workspace?(map(), keyword()) :: boolean()
  def match_workspace?(data, opts) do
    case Keyword.get(opts, :workspace_root) do
      nil -> true
      workspace_root -> data["workspace_root"] == workspace_root
    end
  end

  @doc "True when the document carries a non-blank `forgotten_at` marker."
  @spec memory_forgotten?(map()) :: boolean()
  def memory_forgotten?(data),
    do: is_binary(data["forgotten_at"]) and String.trim(data["forgotten_at"]) != ""

  @doc "True when any search token refers to an incident-related keyword."
  @spec incident_query?([String.t()]) :: boolean()
  def incident_query?(tokens) do
    Enum.any?(
      tokens,
      &(&1 in ["bug", "fix", "timeout", "incident", "deploy", "retry", "retries"])
    )
  end

  @doc "Extracts the session id from a `session:<id>:...` key, defaulting to `\"unknown\"`."
  @spec extract_session_id(term()) :: String.t()
  def extract_session_id("session:" <> rest) do
    rest
    |> String.split(":", parts: 3)
    |> hd()
  end

  def extract_session_id(_), do: "unknown"

  @doc "Builds a `prefix-YYYYMMDD-hash` identifier from the content."
  @spec build_structured_id(String.t(), String.t()) :: String.t()
  def build_structured_id(prefix, content) do
    date = Date.utc_today() |> Date.to_string() |> String.replace("-", "")
    seq = :crypto.hash(:sha256, content) |> Base.encode16() |> String.slice(-8, 8)
    "#{prefix}-#{date}-#{seq}"
  end

  @doc "Builds the short pattern key used to de-duplicate learnings."
  @spec build_pattern_key(String.t(), String.t()) :: String.t()
  def build_pattern_key(category, summary) do
    :crypto.hash(:sha256, category <> "::" <> summary)
    |> Base.encode16()
    |> String.slice(0, 8)
  end

  @doc "Tokenises a search query into lowercase terms of at least two characters."
  @spec search_tokens(term()) :: [String.t()]
  def search_tokens(query) do
    query
    |> to_string()
    |> String.downcase()
    |> String.split(~r/[^[:alnum:]_]+/u, trim: true)
    |> Enum.filter(&(String.length(&1) >= 2))
  end

  @doc "Clamps a score into the 0.0..1.0 range."
  @spec clamp_score(term()) :: float()
  def clamp_score(score) when is_number(score), do: min(1.0, max(0.0, score * 1.0))
  def clamp_score(_), do: 0.0

  @doc "Stringifies the keys of a map."
  @spec stringify_keys(map()) :: map()
  def stringify_keys(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  @doc "Puts the key unless the value is nil."
  @spec maybe_put(map(), term(), term()) :: map()
  def maybe_put(map, _key, nil), do: map
  def maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc """
  Formats a `path#Lstart-Lend` citation from a document payload.
  """
  @spec build_citation(map()) :: String.t()
  def build_citation(data) do
    source = data["path"] || "memory"

    case {data["line_start"], data["line_end"]} do
      {start_line, end_line} when is_integer(start_line) and is_integer(end_line) ->
        "#{source}#L#{start_line}-L#{end_line}"

      {start_line, _} when is_integer(start_line) ->
        "#{source}#L#{start_line}"

      _ ->
        source
    end
  end

  @doc """
  Renders a document search hit. Accepts any map with a `:data` payload, which
  both an Ecto `%Node{}` struct and a plain SQLite row provide.
  """
  @spec document_result(%{data: map()}, map()) :: map()
  def document_result(%{data: data}, scoring) do
    %{
      kind: :document,
      role: "document",
      content: data["content"],
      source: data["path"],
      citation: build_citation(data),
      score: scoring.score,
      signal: scoring.signal,
      signal_score: scoring.signal_score,
      signals: [scoring.signal],
      score_components: scoring.score_components,
      memory_type: data["memory_type"] || "reference",
      importance: data["importance"] || 5,
      access_count: (data["access_count"] || 0) + 1,
      session_id: data["session_id"],
      forgotten?: memory_forgotten?(data)
    }
  end
end
