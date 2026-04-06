defmodule Pincer.Core.Session.Pruner do
  @moduledoc """
  Prunes old tool results from conversation history to reduce context bloat.

  Tool results (file contents, command output) can consume thousands of tokens
  that become irrelevant after subsequent turns. This module replaces old tool
  outputs with compact summaries, preserving recent results intact.

  ## Options

    * `:keep_recent` — number of recent messages to preserve (default: 6)
  """

  @default_keep_recent 6

  @doc """
  Prune tool results older than `keep_recent` messages, replacing them with
  compact summaries. Tool results within the recent window are kept intact.
  """
  @spec prune([map()], keyword()) :: [map()]
  def prune(history, opts \\ []) do
    keep_recent = Keyword.get(opts, :keep_recent, @default_keep_recent)

    {system, messages} = split_system(history)

    total = length(messages)
    cutoff = max(0, total - keep_recent)

    pruned =
      messages
      |> Enum.with_index()
      |> Enum.map(fn {msg, idx} ->
        cond do
          msg["role"] != "tool" -> msg
          tool_content_empty?(msg) -> msg
          idx < cutoff -> summarize(msg)
          true -> msg
        end
      end)

    case system do
      nil -> pruned
      sys -> [sys | pruned]
    end
  end

  defp summarize(msg) do
    content = to_string(msg["content"] || "")
    len = String.length(content)
    %{msg | "content" => "[tool output: #{len} chars, omitted]"}
  end

  defp tool_content_empty?(msg) do
    content = msg["content"]
    content == nil or content == ""
  end

  defp split_system([%{"role" => "system"} = sys | rest]), do: {sys, rest}
  defp split_system(rest), do: {nil, rest}
end
