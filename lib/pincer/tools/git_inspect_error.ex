defmodule Pincer.Adapters.Tools.GitInspectError do
  @moduledoc """
  Pure formatter for `git_inspect` stderr output.
  """

  @doc """
  Formats Git stderr into a short, user-facing error message.
  """
  @spec format(String.t()) :: String.t()
  def format(output) when is_binary(output) do
    trimmed = String.trim(output)

    cond do
      trimmed == "" ->
        "Git command failed."

      String.contains?(trimmed, "not a git repository") ->
        "Path is not a Git repository."

      Regex.match?(~r/pathspec '([^']+)' did not match any file/i, trimmed) ->
        [_, path] = Regex.run(~r/pathspec '([^']+)' did not match any file/i, trimmed)
        "Git path not found: #{path}"

      Regex.match?(~r/ambiguous argument '([^']+)'/i, trimmed) ->
        [_, ref] = Regex.run(~r/ambiguous argument '([^']+)'/i, trimmed)
        "Git reference or path not found: #{ref}"

      true ->
        trimmed
    end
  end
end
