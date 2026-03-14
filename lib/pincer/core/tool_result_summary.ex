defmodule Pincer.Core.ToolResultSummary do
  @moduledoc """
  Pure summarizer for successful tool outputs used by degraded fallback UX.
  """

  @max_lines 4
  @max_chars 220
  @max_items 3

  @doc """
  Builds a concise human-readable summary for a tool message when possible.
  Returns `nil` when no specialized summary applies.
  """
  @spec summarize(map()) :: String.t() | nil
  def summarize(%{"name" => "get_issue", "content" => content}), do: summarize_issue_json(content)
  def summarize(%{"name" => "get_pr", "content" => content}), do: summarize_pr_json(content)

  def summarize(%{"name" => "list_issues", "content" => content}),
    do: summarize_issue_list_json(content)

  def summarize(%{"name" => "list_prs", "content" => content}),
    do: summarize_pr_list_json(content)

  def summarize(%{"name" => "list_commits", "content" => content}),
    do: summarize_commit_list_json(content)

  def summarize(%{"name" => "search_code", "content" => content}),
    do: summarize_code_search_json(content)

  def summarize(%{"name" => "list_repos", "content" => content}),
    do: summarize_repo_list_json(content)

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

  defp summarize_issue_list_json(content) when is_binary(content) do
    with {:ok, payload} <- Jason.decode(content),
         true <- is_list(payload) do
      lines =
        payload
        |> Enum.take(@max_items)
        |> Enum.map(fn issue ->
          "- ##{issue["number"]} #{issue["title"]} (#{issue["state"] || "unknown"}) #{issue["html_url"]}"
        end)

      case lines do
        [] -> nil
        _ -> "Issues:\n" <> Enum.join(lines, "\n")
      end
    else
      _ -> nil
    end
  end

  defp summarize_issue_list_json(_content), do: nil

  defp summarize_pr_list_json(content) when is_binary(content) do
    with {:ok, payload} <- Jason.decode(content),
         true <- is_list(payload) do
      lines =
        payload
        |> Enum.take(@max_items)
        |> Enum.map(fn pr ->
          "- PR ##{pr["number"]} #{pr["title"]} (#{pr["state"] || "unknown"}) #{pr["html_url"]}"
        end)

      case lines do
        [] -> nil
        _ -> "Pull requests:\n" <> Enum.join(lines, "\n")
      end
    else
      _ -> nil
    end
  end

  defp summarize_pr_list_json(_content), do: nil

  defp summarize_commit_list_json(content) when is_binary(content) do
    with {:ok, payload} <- Jason.decode(content),
         true <- is_list(payload) do
      lines =
        payload
        |> Enum.take(@max_items)
        |> Enum.map(fn commit ->
          sha = commit["sha"] || "(no sha)"
          message = commit |> get_in(["commit", "message"]) |> first_line()
          author = get_in(commit, ["commit", "author", "name"])
          date = get_in(commit, ["commit", "author", "date"])

          suffix =
            [author, date]
            |> Enum.reject(&is_nil_or_empty/1)
            |> Enum.join(", ")

          if suffix == "" do
            "- #{sha} #{message}"
          else
            "- #{sha} #{message} (#{suffix})"
          end
        end)

      case lines do
        [] -> nil
        _ -> "Commits:\n" <> Enum.join(lines, "\n")
      end
    else
      _ -> nil
    end
  end

  defp summarize_commit_list_json(_content), do: nil

  defp summarize_code_search_json(content) when is_binary(content) do
    with {:ok, payload} <- Jason.decode(content),
         items when is_list(items) <- payload["items"] do
      lines =
        items
        |> Enum.take(@max_items)
        |> Enum.map(fn item ->
          repo = get_in(item, ["repository", "full_name"]) || "(unknown repo)"
          "- #{repo}: #{item["path"]} #{item["html_url"]}"
        end)

      case lines do
        [] ->
          nil

        _ ->
          "Code search (#{payload["total_count"] || length(items)} matches):\n" <>
            Enum.join(lines, "\n")
      end
    else
      _ -> nil
    end
  end

  defp summarize_code_search_json(_content), do: nil

  defp summarize_repo_list_json(content) when is_binary(content) do
    with {:ok, payload} <- Jason.decode(content),
         true <- is_list(payload) do
      lines =
        payload
        |> Enum.take(@max_items)
        |> Enum.map(fn repo ->
          description = repo["description"] || "no description"
          "- #{repo["full_name"]} - #{description} #{repo["html_url"]}"
        end)

      case lines do
        [] -> nil
        _ -> "Repositories:\n" <> Enum.join(lines, "\n")
      end
    else
      _ -> nil
    end
  end

  defp summarize_repo_list_json(_content), do: nil

  defp first_line(nil), do: ""
  defp first_line(text) when is_binary(text), do: text |> String.split("\n") |> List.first()
  defp first_line(_text), do: ""

  defp is_nil_or_empty(nil), do: true
  defp is_nil_or_empty(""), do: true
  defp is_nil_or_empty(_value), do: false
end
