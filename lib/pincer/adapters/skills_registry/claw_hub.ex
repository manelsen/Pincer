defmodule Pincer.Adapters.SkillsRegistry.ClawHub do
  @moduledoc """
  ClawHub-backed registry adapter for remote skill discovery.

  Expected payloads:
  - list endpoint: `%{"skills" => [%{...}]}`
  - fetch endpoint: `%{"skill" => %{...}}` or a direct skill map
  """

  @type skill :: map()
  @default_base_url "https://api.clawhub.dev"
  @default_registry_path "/v1/skills"

  @spec list_skills(keyword()) :: {:ok, [skill()]} | {:error, term()}
  def list_skills(opts \\ []) do
    url = build_url(opts, @default_registry_path)
    headers = auth_headers(opts)

    with {:ok, %{status: 200, body: body}} <- request(:get, url, headers, opts),
         {:ok, skills} <- parse_skills_list(body) do
      {:ok, skills}
    else
      {:ok, %{status: status}} -> {:error, {:http_error, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec fetch_skill(String.t(), keyword()) :: {:ok, skill()} | {:error, term()}
  def fetch_skill(skill_id, opts \\ [])

  def fetch_skill(skill_id, opts) when is_binary(skill_id) do
    url = build_url(opts, "#{@default_registry_path}/#{URI.encode(skill_id)}")
    headers = auth_headers(opts)

    with {:ok, %{status: 200, body: body}} <- request(:get, url, headers, opts),
         {:ok, skill} <- parse_skill(body),
         true <- skill_identifier(skill) == skill_id do
      {:ok, skill}
    else
      {:ok, %{status: 404}} -> {:error, :not_found}
      {:ok, %{status: status}} -> {:error, {:http_error, status}}
      false -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def fetch_skill(_skill_id, _opts), do: {:error, :not_found}

  defp build_url(opts, default_path) do
    base_url = Keyword.get(opts, :base_url, @default_base_url)
    registry_path = Keyword.get(opts, :registry_path, default_path)
    base = String.trim_trailing(to_string(base_url), "/")
    path = "/" <> String.trim_leading(to_string(registry_path), "/")
    base <> path
  end

  defp auth_headers(opts) do
    api_key = Keyword.get(opts, :api_key) || System.get_env("CLAWHUB_API_KEY")
    headers = [{"accept", "application/json"}]

    if is_binary(api_key) and String.trim(api_key) != "" do
      [{"authorization", "Bearer #{api_key}"} | headers]
    else
      headers
    end
  end

  defp request(method, url, headers, opts) do
    http_client = Keyword.get(opts, :http_client, Req)
    req_opts = [headers: headers, receive_timeout: 15_000]

    case method do
      :get -> http_client.get(url, req_opts)
      _ -> {:error, :unsupported_method}
    end
  rescue
    error -> {:error, error}
  end

  defp parse_skills_list(%{"skills" => skills}) when is_list(skills) do
    {:ok, Enum.filter(skills, &is_map/1)}
  end

  defp parse_skills_list(%{skills: skills}) when is_list(skills) do
    {:ok, Enum.filter(skills, &is_map/1)}
  end

  defp parse_skills_list(other) when is_list(other) do
    {:ok, Enum.filter(other, &is_map/1)}
  end

  defp parse_skills_list(_), do: {:error, :invalid_payload}

  defp parse_skill(%{"skill" => %{} = skill}), do: {:ok, skill}
  defp parse_skill(%{skill: %{} = skill}), do: {:ok, skill}
  defp parse_skill(%{} = skill), do: {:ok, skill}
  defp parse_skill(_), do: {:error, :invalid_payload}

  defp skill_identifier(skill) when is_map(skill) do
    skill["id"] || skill[:id]
  end
end
