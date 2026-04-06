defmodule Pincer.Core.Skills.Loader do
  @moduledoc """
  Discover and load skills from three tiers: bundled, shared, and workspace.

  Resolution order (highest priority wins):
    1. Workspace — `workspaces/<agent>/.pincer/skills/`
    2. Shared    — `~/.pincer/skills/`
    3. Bundled   — `priv/skills/`

  Each skill is a directory containing a `SKILL.md` file with YAML frontmatter.
  """

  alias Pincer.Core.Skills.Manifest

  @skill_file "SKILL.md"

  @doc "Discover skills from all three tiers with workspace > shared > bundled resolution."
  @spec discover(keyword()) :: [Manifest.t()]
  def discover(opts \\ []) do
    bundled = Keyword.get(opts, :bundled)
    shared = Keyword.get(opts, :shared)
    workspace = Keyword.get(opts, :workspace)

    bundled_skills = load_tier(bundled)
    shared_skills = load_tier(shared)
    workspace_skills = load_tier(workspace)

    # Merge: workspace > shared > bundled by name
    all =
      (workspace_skills ++ shared_skills ++ bundled_skills)
      |> Enum.uniq_by(& &1.name)

    all
  end

  @doc "Check requirements for a manifest, returning issues for unmet ones."
  @spec check_requirements(Manifest.t() | map()) :: [%{type: atom(), binary: String.t()}]
  def check_requirements(%{requirements: requirements}) when is_list(requirements) do
    Enum.flat_map(requirements, fn req ->
      case req["binary"] do
        nil ->
          []

        binary ->
          if System.find_executable(binary) do
            []
          else
            [%{type: :missing_binary, binary: binary}]
          end
      end
    end)
  end

  def check_requirements(_), do: []

  defp load_tier(nil), do: []

  defp load_tier(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&File.dir?(Path.join(dir, &1)))
        |> Enum.map(fn name ->
          skill_path = Path.join([dir, name, @skill_file])

          case File.read(skill_path) do
            {:ok, content} ->
              case Manifest.parse(content) do
                {:ok, manifest} ->
                  %{manifest | source_path: Path.join(dir, name)}

                {:error, _} ->
                  nil
              end

            {:error, _} ->
              nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      {:error, _} ->
        []
    end
  end
end
