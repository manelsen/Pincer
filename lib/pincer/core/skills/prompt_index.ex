defmodule Pincer.Core.Skills.PromptIndex do
  @moduledoc """
  Discovers eligible workspace, shared, and bundled skills and formats a bounded,
  sanitized index block for injection into the agent's system prompt.
  """

  alias Pincer.Core.AgentPaths
  alias Pincer.Core.Skills.Loader

  @default_max_chars 2_400
  @default_max_skills 15
  @control_and_bidi_re ~r/[\x{0000}-\x{001F}\x{200B}-\x{200F}\x{202A}-\x{202E}\x{2066}-\x{2069}\x{FEFF}]/u

  @doc """
  Builds the system-prompt skill index block for `workspace_path`.

  Returns `""` when no skills with satisfied requirements are discovered.
  """
  @spec build(String.t(), keyword()) :: String.t()
  def build(workspace_path, opts \\ []) when is_binary(workspace_path) and is_list(opts) do
    max_chars = Keyword.get(opts, :max_chars, @default_max_chars)
    max_skills = Keyword.get(opts, :max_skills, @default_max_skills)

    workspace_dir = Keyword.get(opts, :workspace_dir, AgentPaths.skills_dir(workspace_path))
    shared_dir = Keyword.get(opts, :shared_dir, default_shared_dir())
    bundled_dir = Keyword.get(opts, :bundled_dir, default_bundled_dir())

    ready_skills =
      Loader.discover(workspace: workspace_dir, shared: shared_dir, bundled: bundled_dir)
      |> Enum.filter(&(Loader.check_requirements(&1) == []))
      |> Enum.take(max_skills)

    case ready_skills do
      [] ->
        ""

      skills ->
        format_index(skills, max_chars)
    end
  end

  # --- Private ---

  defp format_index(skills, max_chars) do
    header =
      "## LEARNED & AVAILABLE SKILLS:\nRead the matching SKILL.md when a task matches one of these skills.\n"

    lines =
      Enum.map(skills, fn skill ->
        name = sanitize(skill.name)
        version = sanitize(skill.version || "0.1.0")
        desc = skill.description |> sanitize() |> String.slice(0, 160)
        path = sanitize(skill.source_path || "")
        "- **#{name}** (v#{version}): #{desc} [#{path}]"
      end)

    {built, _count} =
      Enum.reduce_while(lines, {header, 0}, fn line, {acc, count} ->
        candidate = if count == 0, do: acc <> line, else: acc <> "\n" <> line

        if String.length(candidate) <= max_chars do
          {:cont, {candidate, count + 1}}
        else
          {:halt, {acc, count}}
        end
      end)

    cond do
      String.length(built) > max_chars ->
        String.slice(built, 0, max_chars)

      built == header ->
        [first | _] = lines
        String.slice(header <> first, 0, max_chars)

      true ->
        built
    end
  end

  defp sanitize(text) do
    text
    |> to_string()
    |> String.replace(~r/[\r\n]+/, " ")
    |> String.replace(@control_and_bidi_re, "")
    |> String.trim()
  end

  defp default_shared_dir, do: Path.expand("~/.pincer/skills")

  defp default_bundled_dir do
    Application.app_dir(:pincer, "priv/skills")
  rescue
    ArgumentError -> nil
  end
end
