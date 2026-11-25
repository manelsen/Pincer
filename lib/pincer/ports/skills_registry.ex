defmodule Pincer.Ports.SkillsRegistry do
  @moduledoc """
  Root application entry point for `PincerPorts.SkillsRegistry`.
  """

  @doc """
  Lists skills using the selected adapter.
  """
  defdelegate list_skills(selector, opts), to: PincerPorts.SkillsRegistry

  @doc """
  Fetches a skill by ID using the selected adapter.
  """
  defdelegate fetch_skill(selector, skill_id, opts), to: PincerPorts.SkillsRegistry
end
