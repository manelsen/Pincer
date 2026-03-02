defmodule Pincer.Core.Skills do
  @moduledoc """
  Core skills discovery and installation governance.

  Security gates enforced in v1:
  - trusted source host allowlist
  - checksum format validation (`sha256:<64hex>`)
  - optional expected-checksum match
  - install path confinement inside sandbox root
  """

  alias Pincer.Adapters.SkillsRegistry.Local, as: LocalRegistry

  @default_sandbox_root "skills"
  @skill_id_regex ~r/^[a-zA-Z0-9._-]+$/
  @checksum_regex ~r/^sha256:[0-9a-fA-F]{64}$/

  @type install_result :: %{
          id: String.t(),
          source: String.t(),
          checksum: String.t(),
          install_path: String.t()
        }

  @spec discover(keyword()) :: {:ok, [map()]} | {:error, term()}
  def discover(opts \\ []) do
    {registry, registry_opts} = registry_config(opts)
    registry.list_skills(registry_opts)
  end

  @spec install(String.t(), keyword()) :: {:ok, install_result()} | {:error, term()}
  def install(skill_id, opts \\ [])

  def install(skill_id, opts) when is_binary(skill_id) do
    allow_install? = Keyword.get(opts, :allow_install, false)
    {registry, registry_opts} = registry_config(opts)
    allowed_sources = normalize_allowed_sources(Keyword.get(opts, :allowed_sources, []))

    allowed_schemes =
      normalize_allowed_schemes(Keyword.get(opts, :allowed_source_schemes, ["https"]))

    expected_checksum = Keyword.get(opts, :expected_checksum)
    sandbox_root = Keyword.get(opts, :sandbox_root, @default_sandbox_root)
    installer = Keyword.get(opts, :installer, &default_installer/2)

    with :ok <- ensure_install_allowed(allow_install?),
         :ok <- validate_skill_id(skill_id),
         {:ok, skill} <- registry.fetch_skill(skill_id, registry_opts),
         :ok <- validate_skill_identity(skill_id, skill),
         :ok <- validate_source(skill, allowed_sources, allowed_schemes),
         {:ok, checksum} <- validate_checksum(skill, expected_checksum),
         {:ok, install_path} <- safe_install_path(sandbox_root, skill_id),
         :ok <- installer.(skill, install_path) do
      {:ok,
       %{
         id: skill_id,
         source: source(skill),
         checksum: checksum,
         install_path: install_path
       }}
    end
  end

  def install(_skill_id, _opts), do: {:error, :invalid_skill_id}

  defp ensure_install_allowed(true), do: :ok
  defp ensure_install_allowed(_), do: {:error, :install_not_allowed}

  defp registry_config(opts) do
    registry = Keyword.get(opts, :registry, LocalRegistry)
    registry_opts = Keyword.get(opts, :registry_opts, [])
    {registry, registry_opts}
  end

  defp validate_skill_id(skill_id) do
    if Regex.match?(@skill_id_regex, skill_id) do
      :ok
    else
      {:error, :invalid_skill_id}
    end
  end

  defp validate_skill_identity(skill_id, skill) do
    if to_string(skill["id"] || skill[:id] || "") == skill_id do
      :ok
    else
      {:error, :registry_id_mismatch}
    end
  end

  defp validate_source(skill, allowed_sources, allowed_schemes) do
    value = source(skill)
    uri = URI.parse(value)
    host = normalize_host(uri.host)
    scheme = normalize_scheme(uri.scheme)

    cond do
      value == "" ->
        {:error, :untrusted_source}

      scheme in [nil, ""] ->
        {:error, :untrusted_source}

      not Enum.member?(allowed_schemes, scheme) ->
        {:error, :untrusted_source}

      is_nil(host) or host == "" ->
        {:error, :untrusted_source}

      Enum.member?(allowed_sources, "*") ->
        :ok

      allowed_host?(host, allowed_sources) ->
        :ok

      true ->
        {:error, :untrusted_source}
    end
  end

  defp validate_checksum(skill, expected_checksum) do
    checksum = checksum(skill)

    cond do
      not Regex.match?(@checksum_regex, checksum) ->
        {:error, :invalid_checksum}

      is_binary(expected_checksum) and expected_checksum != checksum ->
        {:error, {:checksum_mismatch, expected_checksum, checksum}}

      true ->
        {:ok, checksum}
    end
  end

  defp safe_install_path(sandbox_root, skill_id) do
    root = Path.expand(sandbox_root)

    with :ok <- ensure_not_symlink_root(root),
         :ok <- File.mkdir_p(root) do
      install_path = Path.expand(Path.join(root, skill_id))

      cond do
        install_path == root ->
          {:ok, install_path}

        String.starts_with?(install_path, root <> "/") ->
          {:ok, install_path}

        true ->
          {:error, {:unsafe_install_path, install_path}}
      end
    else
      {:error, {:unsafe_sandbox_root, _} = reason} ->
        {:error, reason}

      {:error, reason} ->
        {:error, {:unsafe_install_path, reason}}
    end
  end

  defp ensure_not_symlink_root(root) do
    case :file.read_link(String.to_charlist(root)) do
      {:ok, _target} -> {:error, {:unsafe_sandbox_root, root}}
      {:error, :einval} -> :ok
      {:error, :enoent} -> :ok
      {:error, _other} -> :ok
    end
  end

  defp normalize_allowed_schemes(list) when is_list(list) do
    list
    |> Enum.map(&to_string/1)
    |> Enum.map(&normalize_scheme/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_allowed_schemes(_), do: ["https"]

  defp allowed_host?(host, allowed_sources) do
    Enum.any?(allowed_sources, fn source_rule ->
      rule = normalize_host(source_rule)

      cond do
        is_nil(rule) ->
          false

        String.starts_with?(rule, "*.") ->
          suffix = String.trim_leading(rule, "*.")
          host != suffix and String.ends_with?(host, "." <> suffix)

        true ->
          host == rule
      end
    end)
  end

  defp normalize_host(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> nil
      host -> host
    end
  end

  defp normalize_host(_), do: nil

  defp normalize_scheme(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> nil
      scheme -> scheme
    end
  end

  defp normalize_scheme(_), do: nil

  defp normalize_allowed_sources(list) when is_list(list) do
    list
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&normalize_host/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_allowed_sources(_), do: []

  defp default_installer(skill, install_path) do
    with :ok <- File.mkdir_p(install_path),
         {:ok, encoded} <- Jason.encode(skill, pretty: true),
         :ok <- File.write(Path.join(install_path, "skill.json"), encoded <> "\n") do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp source(skill) when is_map(skill) do
    skill["source"] || skill[:source] || ""
  end

  defp checksum(skill) when is_map(skill) do
    skill["checksum"] || skill[:checksum] || ""
  end
end
