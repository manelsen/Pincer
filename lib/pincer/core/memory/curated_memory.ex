defmodule Pincer.Core.Memory.CuratedMemory do
  @moduledoc """
  Single enforcement point for the curated memory files (`MEMORY.md` / `USER.md`).

  Curated memory is injected into every system prompt, so it must stay within a
  fixed character budget. This module owns both directions:

    * `read/3` bounds files that are already oversized on disk (for example a
      hand-edited file or content written by an older version), keeping the head
      of the file at a line boundary and appending an explicit `[truncated]`
      marker so the model knows the text is incomplete.
    * `write/4` caps what Pincer persists, truncating at a line boundary and
      logging a warning when content is dropped.

  Caps default to `config :pincer, :curated_memory_limits` (4_000 for
  `MEMORY.md`, 2_500 for `USER.md`) and can be overridden per call with
  `opts[:max_chars]`, which keeps tests fast and deterministic.
  """

  require Logger
  alias Pincer.Core.AgentPaths

  @default_limits %{memory: 4_000, user: 2_500}
  @marker "\n[truncated]"

  @type kind :: :memory | :user

  @doc """
  Reads a curated memory file, bounding the result to the configured cap.

  Returns `""` when the file does not exist. Oversized files keep their head up
  to a line boundary and end with `[truncated]`; the returned binary never
  exceeds the cap.
  """
  @spec read(String.t(), kind(), keyword()) :: String.t()
  def read(workspace_path, kind, opts \\ []) when is_binary(workspace_path) do
    cap = cap(kind, opts)
    text = AgentPaths.read_file(path(workspace_path, kind))

    if byte_size(text) <= cap do
      text
    else
      bound(text, cap)
    end
  end

  @doc """
  Writes a curated memory file, truncating content to the configured cap.

  Truncation happens at a line boundary so the persisted markdown never ends
  mid-line, and a warning is logged whenever content is dropped. Returns the
  number of bytes actually written.
  """
  @spec write(String.t(), kind(), String.t(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def write(workspace_path, kind, content, opts \\ [])
      when is_binary(workspace_path) and is_binary(content) do
    cap = cap(kind, opts)
    {bounded, truncated?} = truncate_lines(content, cap)

    if truncated? do
      Logger.warning(
        "[CURATED_MEMORY] truncated #{kind} file from #{byte_size(content)} to " <>
          "#{byte_size(bounded)} bytes (cap #{cap})"
      )
    end

    file = path(workspace_path, kind)
    File.mkdir_p!(Path.dirname(file))

    case File.write(file, bounded) do
      :ok -> {:ok, byte_size(bounded)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp bound(text, cap) do
    budget = max(cap - byte_size(@marker), 0)
    {body, _truncated?} = truncate_lines(text, budget)
    body <> @marker
  end

  # Keeps whole lines from the head of `text` while the accumulated byte size
  # stays within `cap`. When even the first line does not fit, falls back to a
  # hard byte cut so the cap is still respected.
  defp truncate_lines(text, cap) when byte_size(text) <= cap, do: {text, false}

  defp truncate_lines(text, cap) do
    {kept, _size} =
      text
      |> String.split("\n")
      |> Enum.reduce_while({[], 0}, fn line, {acc, size} ->
        addition = if acc == [], do: byte_size(line), else: 1 + byte_size(line)

        if size + addition <= cap do
          {:cont, {[line | acc], size + addition}}
        else
          {:halt, {acc, size}}
        end
      end)

    case kept do
      [] -> {hard_cut(text, cap), true}
      _ -> {kept |> Enum.reverse() |> Enum.join("\n"), true}
    end
  end

  defp hard_cut(text, cap) do
    candidate = binary_part(text, 0, min(cap, byte_size(text)))

    case :unicode.characters_to_binary(candidate) do
      {:incomplete, valid, _rest} -> valid
      {:error, valid, _rest} -> valid
      valid when is_binary(valid) -> valid
    end
  end

  defp cap(kind, opts) do
    Keyword.get(opts, :max_chars) || configured_limit(kind)
  end

  defp configured_limit(kind) do
    configured = Application.get_env(:pincer, :curated_memory_limits, @default_limits)
    Map.get(configured, kind) || Map.fetch!(@default_limits, kind)
  end

  defp path(workspace_path, :memory), do: AgentPaths.memory_path(workspace_path)
  defp path(workspace_path, :user), do: AgentPaths.user_path(workspace_path)
end
