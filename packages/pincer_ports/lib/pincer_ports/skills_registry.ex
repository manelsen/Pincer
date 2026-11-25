defmodule PincerPorts.SkillsRegistry do
  @moduledoc """
  Contract and dispatcher for skills catalog adapters.

  Resolve the named selectors `:local` and `:clawhub` through the
  `:skills_registry_adapters` configuration. An explicit adapter module
  can also be supplied on each call.
  """

  @type skill :: map()
  @type selector :: :local | :clawhub | module()

  @callback list_skills(keyword()) :: {:ok, [skill()]} | {:error, term()}
  @callback fetch_skill(String.t(), keyword()) :: {:ok, skill()} | {:error, term()}

  @doc """
  Lists skills using the selected adapter.
  """
  @spec list_skills(selector(), keyword()) :: {:ok, [skill()]} | {:error, term()}
  def list_skills(selector, opts), do: adapter(selector).list_skills(opts)

  @doc """
  Fetches a skill by ID using the selected adapter.
  """
  @spec fetch_skill(selector(), String.t(), keyword()) :: {:ok, skill()} | {:error, term()}
  def fetch_skill(selector, skill_id, opts), do: adapter(selector).fetch_skill(skill_id, opts)

  defp adapter(selector) when selector in [:local, :clawhub] do
    :pincer
    |> Application.fetch_env!(:skills_registry_adapters)
    |> Map.fetch!(selector)
  end

  defp adapter(module), do: module
end
