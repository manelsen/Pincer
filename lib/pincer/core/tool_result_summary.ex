defmodule Pincer.Core.ToolResultSummary do
  @moduledoc """
  Pure summarizer for successful tool outputs used by degraded fallback UX.
  """

  @max_lines 4
  @max_chars 220

  @doc """
  Builds a concise human-readable summary for a tool message when possible.
  Returns `nil` when no specialized summary applies.
  """
  @spec summarize(map()) :: String.t() | nil
  def summarize(%{"name" => "get_issue", "content" => content}), do: summarize_issue_json(content)
  def summarize(%{"name" => "get_pr", "content" => content}), do: summarize_pr_json(content)

  def summarize(%{"name" => "git_inspect", "content" => content}),
    do: summarize_git_output(content)

  def summarize(_msg), do: nil

  defp summarize_issue_json(content) when is_binary(content) do
    with {:ok, payload} <- Jason.decode(content),
         number when is_integer(number) <- payload["number"],
         title when is_binary(title) <- payload["title"] do
      [
        "Issue ##{number}: #{title}",
        "State: #{payload["state"] || "unknown"}",
        payload["html_url"]
      ]
      |> Enum.reject(&is_nil_or_empty/1)
      |> Enum.join("\n")
    else
      _ -> nil
    end
  end

  defp summarize_pr_json(content) when is_binary(content) do
    with {:ok, payload} <- Jason.decode(content),
         number when is_integer(number) <- payload["number"],
         title when is_binary(title) <- payload["title"] do
      [
        "PR ##{number}: #{title}",
        "State: #{payload["state"] || "unknown"}",
        payload["html_url"]
      ]
      |> Enum.reject(&is_nil_or_empty/1)
      |> Enum.join("\n")
    else
      _ -> nil
    end
  end

  defp summarize_git_output(content) when is_binary(content) do
    lines =
      content
      |> String.split("\n")
      |> Enum.map(&String.trim_trailing/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.take(@max_lines)

    case lines do
      [] -> nil
      _ -> lines |> Enum.join("\n") |> String.slice(0, @max_chars)
    end
  end

  defp summarize_git_output(_content), do: nil

  defp is_nil_or_empty(nil), do: true
  defp is_nil_or_empty(""), do: true
  defp is_nil_or_empty(_value), do: false
end
