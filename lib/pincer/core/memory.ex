defmodule Pincer.Core.Memory do
  @moduledoc """
  Two-layer memory manager for `MEMORY.md` and `HISTORY.md`.

  Layer contract:
  - `HISTORY.md`: structured rolling log of recent session snapshots.
  - `MEMORY.md`: curated long-term memory plus consolidation markers for old history entries.
  """

  @default_history_path "HISTORY.md"
  @default_memory_path "MEMORY.md"
  @default_window_size 20
  @history_header "# Session History\n\n"
  @memory_header "# Long-term Memory\n\n"
  @consolidation_header "### History Consolidation"

  @type append_result :: %{
          status: :appended | :noop,
          digest: String.t(),
          history_path: String.t()
        }

  @type consolidation_result :: %{
          status: :noop | :consolidated,
          moved: non_neg_integer(),
          kept: non_neg_integer(),
          history_path: String.t(),
          memory_path: String.t()
        }

  @doc """
  Appends a session snapshot to `HISTORY.md` unless an identical digest already exists.
  """
  def append_history(content, opts \\ [])

  @spec append_history(String.t(), keyword()) :: {:ok, append_result()} | {:error, term()}
  def append_history(content, opts) when is_binary(content) do
    history_path = Keyword.get(opts, :history_path, @default_history_path)
    session_id = normalize_session_id(Keyword.get(opts, :session_id, "unknown"))
    timestamp = now_iso8601(opts)
    normalized_content = normalize_content(content)
    digest = digest_for(session_id, normalized_content)

    entry = %{
      digest: digest,
      session_id: session_id,
      timestamp: timestamp,
      content: normalized_content
    }

    with {:ok, existing_content} <- read_text(history_path),
         entries = parse_entries(existing_content),
         false <- Enum.any?(entries, &(&1.digest == digest)),
         :ok <- write_text(history_path, append_entry_block(existing_content, entry)) do
      {:ok, %{status: :appended, digest: digest, history_path: history_path}}
    else
      true ->
        {:ok, %{status: :noop, digest: digest, history_path: history_path}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def append_history(_content, _opts), do: {:error, :invalid_content}

  @doc """
  Enforces rolling window on `HISTORY.md` and records rolled entries into `MEMORY.md`.
  """
  @spec consolidate_window(keyword()) :: {:ok, consolidation_result()} | {:error, term()}
  def consolidate_window(opts \\ []) do
    history_path = Keyword.get(opts, :history_path, @default_history_path)
    memory_path = Keyword.get(opts, :memory_path, @default_memory_path)
    window_size = window_size(opts)

    with {:ok, history_text} <- read_text(history_path),
         entries = parse_entries(history_text),
         {:ok, result} <- maybe_consolidate(entries, history_path, memory_path, window_size) do
      {:ok, result}
    end
  end

  @doc """
  Records a session snapshot into history and applies consolidation window.
  """
  @spec record_session(String.t(), keyword()) ::
          {:ok, %{append: append_result(), consolidate: consolidation_result()}}
          | {:error, term()}
  def record_session(content, opts \\ []) do
    with {:ok, append_result} <- append_history(content, opts),
         {:ok, consolidate_result} <- consolidate_window(opts) do
      {:ok, %{append: append_result, consolidate: consolidate_result}}
    end
  end

  defp maybe_consolidate(entries, history_path, memory_path, window_size) do
    total = length(entries)

    if total <= window_size do
      {:ok,
       %{
         status: :noop,
         moved: 0,
         kept: total,
         history_path: history_path,
         memory_path: memory_path
       }}
    else
      moved_count = total - window_size
      {moved_entries, kept_entries} = Enum.split(entries, moved_count)

      with {:ok, memory_text} <- read_text(memory_path),
           :ok <- write_text(memory_path, consolidate_memory(memory_text, moved_entries)),
           :ok <- write_text(history_path, render_history_file(kept_entries)) do
        {:ok,
         %{
           status: :consolidated,
           moved: moved_count,
           kept: length(kept_entries),
           history_path: history_path,
           memory_path: memory_path
         }}
      end
    end
  end

  defp append_entry_block(existing_content, entry) do
    existing_content = String.trim_trailing(existing_content)
    block = render_entry(entry)

    cond do
      existing_content == "" ->
        @history_header <> block <> "\n"

      true ->
        existing_content <> "\n\n" <> block <> "\n"
    end
  end

  defp consolidate_memory(existing_memory, moved_entries) do
    existing_memory = String.trim_trailing(existing_memory)

    new_lines =
      moved_entries
      |> Enum.reject(fn entry -> String.contains?(existing_memory, "[HIST:#{entry.digest}]") end)
      |> Enum.map(&memory_summary_line/1)

    cond do
      new_lines == [] and existing_memory == "" ->
        @memory_header

      new_lines == [] ->
        existing_memory <> "\n"

      existing_memory == "" ->
        @memory_header <> @consolidation_header <> "\n" <> Enum.join(new_lines, "\n") <> "\n"

      String.contains?(existing_memory, @consolidation_header) ->
        existing_memory <> "\n" <> Enum.join(new_lines, "\n") <> "\n"

      true ->
        existing_memory <>
          "\n\n" <> @consolidation_header <> "\n" <> Enum.join(new_lines, "\n") <> "\n"
    end
  end

  defp render_history_file([]), do: @history_header

  defp render_history_file(entries) do
    @history_header <> Enum.map_join(entries, "\n\n", &render_entry/1) <> "\n"
  end

  defp render_entry(entry) do
    """
    <!-- PINCER_HISTORY digest=#{entry.digest} session=#{entry.session_id} at=#{entry.timestamp} -->
    #{entry.content}
    <!-- /PINCER_HISTORY -->
    """
    |> String.trim()
  end

  defp parse_entries(content) when is_binary(content) do
    regex =
      ~r/<!-- PINCER_HISTORY digest=([a-f0-9]+) session=([^\s]+) at=([^\s]+) -->\n(.*?)\n<!-- \/PINCER_HISTORY -->/ms

    Regex.scan(regex, content, capture: :all_but_first)
    |> Enum.map(fn [digest, session_id, timestamp, entry_content] ->
      %{
        digest: digest,
        session_id: session_id,
        timestamp: timestamp,
        content: normalize_content(entry_content)
      }
    end)
  end

  defp memory_summary_line(entry) do
    "- [HIST:#{entry.digest}] #{entry.timestamp} session=#{entry.session_id}: #{excerpt(entry.content)}"
  end

  defp excerpt(content) do
    content
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> "(empty)"
      [line | _] -> line
    end
    |> String.slice(0, 180)
  end

  defp normalize_content(content) do
    content
    |> String.trim()
    |> case do
      "" -> "(empty session content)"
      value -> value
    end
  end

  defp normalize_session_id(session_id) do
    session_id
    |> to_string()
    |> String.trim()
    |> String.replace(~r/\s+/, "_")
    |> case do
      "" -> "unknown"
      value -> value
    end
  end

  defp now_iso8601(opts) do
    case Keyword.get(opts, :now_fn) do
      now_fn when is_function(now_fn, 0) ->
        case now_fn.() do
          %DateTime{} = dt -> DateTime.to_iso8601(dt)
          value when is_binary(value) -> value
          _ -> DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
        end

      _ ->
        DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    end
  end

  defp digest_for(session_id, content) do
    :sha256
    |> :crypto.hash("#{session_id}\n#{content}")
    |> Base.encode16(case: :lower)
    |> binary_part(0, 12)
  end

  defp window_size(opts) do
    from_opts = Keyword.get(opts, :window_size)

    value =
      cond do
        is_integer(from_opts) -> from_opts
        true -> Application.get_env(:pincer, :memory_window_size, @default_window_size)
      end

    if is_integer(value) and value >= 0, do: value, else: @default_window_size
  end

  defp read_text(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:ok, ""}
      {:error, reason} -> {:error, {:read_failed, path, reason}}
    end
  end

  defp write_text(path, content) do
    dir = Path.dirname(path)

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(path, content) do
      :ok
    else
      {:error, reason} ->
        {:error, {:write_failed, path, reason}}
    end
  end
end
