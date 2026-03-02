defmodule Pincer.Adapters.SkillsRegistry.Local do
  @moduledoc """
  Local registry adapter for skills catalog lookup.

  The catalog can be provided explicitly via options or through app env:
  - `opts[:registry]`
  - `Application.get_env(:pincer, :skills_registry, [])`
  """

  @type skill :: map()

  @spec list_skills(keyword()) :: {:ok, [skill()]} | {:error, term()}
  def list_skills(opts \\ []) do
    registry =
      Keyword.get_lazy(opts, :registry, fn ->
        Application.get_env(:pincer, :skills_registry, [])
      end)

    normalize_registry(registry)
  end

  @spec fetch_skill(String.t(), keyword()) :: {:ok, skill()} | {:error, :not_found | term()}
  def fetch_skill(skill_id, opts \\ [])

  def fetch_skill(skill_id, opts) when is_binary(skill_id) do
    with {:ok, skills} <- list_skills(opts) do
      case Enum.find(skills, fn skill -> skill_identifier(skill) == skill_id end) do
        nil -> {:error, :not_found}
        skill -> {:ok, skill}
      end
    end
  end

  def fetch_skill(_skill_id, _opts), do: {:error, :not_found}

  defp normalize_registry(%{"skills" => skills}), do: normalize_registry(skills)
  defp normalize_registry(%{skills: skills}), do: normalize_registry(skills)

  defp normalize_registry(skills) when is_list(skills) do
    {:ok, Enum.filter(skills, &is_map/1)}
  end

  defp normalize_registry(other), do: {:error, {:invalid_registry, other}}

  defp skill_identifier(skill) when is_map(skill) do
    skill["id"] || skill[:id]
  end
end
