defmodule Pincer.Core.ToolAnswerPatternPolicy do
  @moduledoc """
  Builds targeted post-tool answer guidance for tool families that benefit from
  explicit summarization patterns.
  """

  @github_tool_names ~w(github get_issue get_pr list_issues list_prs list_commits search_code)
  @git_tool_names ~w(git_inspect)

  @doc """
  Returns extra grounding text for the given tool messages.
  """
  @spec build([map()]) :: String.t()
  def build(tool_messages) when is_list(tool_messages) do
    names =
      tool_messages
      |> Enum.map(&Map.get(&1, "name"))
      |> Enum.filter(&is_binary/1)
      |> MapSet.new()

    []
    |> maybe_add_git_examples(names)
    |> maybe_add_github_examples(names)
    |> Enum.join("\n\n")
  end

  defp maybe_add_git_examples(parts, names) do
    if Enum.any?(@git_tool_names, &MapSet.member?(names, &1)) do
      parts ++
        [
          """
          For Git inspection tools, answer with a compact factual summary.
          Good patterns:
          - status: branch, ahead/behind if present, staged/unstaged/untracked files, conflicts if any
          - log: latest commits with subject, short SHA, author/date when useful
          - diff: summarize touched files and key changes; say plainly if diff is empty
          - branches: list current branch and notable alternatives
          Do not say the Git command failed if the tool returned useful output.
          """
          |> String.trim()
        ]
    else
      parts
    end
  end

  defp maybe_add_github_examples(parts, names) do
    if Enum.any?(@github_tool_names, &MapSet.member?(names, &1)) do
      parts ++
        [
          """
          For GitHub tools, summarize the object you got back instead of dumping raw JSON.
          Good patterns:
          - get_issue/get_pr: title, state, author, key labels, created/updated date, URL, and the most relevant body points
          - list_issues/list_prs: short bullet list with number, title, state, URL
          - list_commits: short bullet list with SHA, subject, author/date
          If the tool succeeded, explain what it returned. Only call it an error when the tool actually failed.
          """
          |> String.trim()
        ]
    else
      parts
    end
  end
end
