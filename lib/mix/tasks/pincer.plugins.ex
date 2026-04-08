defmodule Mix.Tasks.Pincer.Plugins do
  @moduledoc """
  Gerencia plugins do Pincer.

  ## Subcomandos

      mix pincer.plugins list                        # Lista plugins instalados
      mix pincer.plugins enable  <name>               # Habilita canal no config.yaml
      mix pincer.plugins disable <name>               # Desabilita canal no config.yaml
      mix pincer.plugins enable  <name> --config path # Usa config alternativo
      mix pincer.plugins install <name>               # Instala plugin (monorepo ou Hex)
      mix pincer.plugins remove  <name>               # Remove dep Hex do mix.exs + deps.clean
  """

  use Mix.Task
  use Boundary, classify_to: Pincer.Mix

  alias Pincer.Plugin.Manifest

  @shortdoc "Gerencia plugins do Pincer (list | enable | install | remove)"

  @switches [config: :string, yes: :boolean]

  @impl Mix.Task
  def run(["status" | rest]) do
    Application.ensure_all_started(:yaml_elixir)
    {opts, _, _} = OptionParser.parse(rest, strict: @switches)
    config_path = opts[:config] || "config.yaml"

    manifests = Manifest.discover()
    config_channels = read_config_channels(config_path)

    Mix.shell().info("Plugin status  (config: #{config_path})\n")
    Mix.shell().info(String.pad_trailing("ID", 16) <> String.pad_trailing("KIND", 10) <> "STATE")
    Mix.shell().info(String.duplicate("─", 40))

    Enum.each(manifests, fn m ->
      enabled = get_in(config_channels, [m.id, "enabled"])
      state = if enabled == true, do: "✓ enabled", else: "✗ disabled"

      Mix.shell().info(
        String.pad_trailing(m.id, 16) <> String.pad_trailing(to_string(m.kind), 10) <> state
      )
    end)

    Mix.shell().info("")
  end

  def run(["list" | _rest]) do
    Application.ensure_all_started(:yaml_elixir)
    manifests = Manifest.discover()

    if manifests == [] do
      Mix.shell().info("Nenhum plugin encontrado.")
    else
      Mix.shell().info("Plugins instalados:\n")
      Enum.each(manifests, &print_manifest/1)
    end
  end

  def run(["enable", name | rest]) do
    {opts, _, _} = OptionParser.parse(rest, strict: @switches)
    config_path = opts[:config] || "config.yaml"

    case File.read(config_path) do
      {:error, _} ->
        Mix.shell().error("Config file not found: #{config_path}")

      {:ok, content} ->
        case set_channel_enabled(content, name, true) do
          {:ok, updated} ->
            File.write!(config_path, updated)
            Mix.shell().info("✅ Plugin '#{name}' enabled in #{config_path}")
            Mix.shell().info("   Restart Pincer to apply changes.")

          {:error, :channel_not_found} ->
            Mix.shell().error(
              "Channel '#{name}' not found in #{config_path}. " <>
                "Add it under the `channels:` section first."
            )
        end
    end
  end

  def run(["disable", name | rest]) do
    {opts, _, _} = OptionParser.parse(rest, strict: @switches)
    config_path = opts[:config] || "config.yaml"

    case File.read(config_path) do
      {:error, _} ->
        Mix.shell().error("Config file not found: #{config_path}")

      {:ok, content} ->
        case set_channel_enabled(content, name, false) do
          {:ok, updated} ->
            File.write!(config_path, updated)
            Mix.shell().info("🔴 Plugin '#{name}' disabled in #{config_path}")
            Mix.shell().info("   Restart Pincer to apply changes.")

          {:error, :channel_not_found} ->
            Mix.shell().error(
              "Channel '#{name}' not found in #{config_path}. " <>
                "Add it under the `channels:` section first."
            )
        end
    end
  end

  def run(["remove", name | rest]) do
    Application.ensure_all_started(:yaml_elixir)
    {opts, _, _} = OptionParser.parse(rest, strict: @switches)
    config_path = opts[:config] || "config.yaml"
    force = opts[:yes] || false

    manifests = Manifest.discover()

    case Enum.find(manifests, &(&1.id == name)) do
      nil ->
        Mix.shell().error("Plugin '#{name}' not found. Is it installed?")

      manifest ->
        package_atom = manifest_to_package_atom(manifest)
        mix_exs_path = "mix.exs"

        if path_dep?(package_atom) do
          Mix.shell().info("""
          '#{name}' is a bundled path dependency — its source lives inside this
          repository and cannot be removed via this command.

          To stop it from loading at runtime, run:

              mix pincer.plugins disable #{name}
          """)
        else
          confirmed =
            force ||
              Mix.shell().yes?(
                "Remove Hex dep '#{package_atom}' from #{mix_exs_path} and clean? [y/N]"
              )

          if confirmed do
            # 1. Disable in config.yaml (best-effort; ignore if channel not configured)
            case File.read(config_path) do
              {:ok, content} ->
                case set_channel_enabled(content, name, false) do
                  {:ok, updated} ->
                    File.write!(config_path, updated)
                    Mix.shell().info("  ✓ Disabled '#{name}' in #{config_path}")

                  {:error, :channel_not_found} ->
                    :ok
                end

              _ ->
                :ok
            end

            # 2. Remove dep line from mix.exs
            case remove_dep_from_mix_exs(mix_exs_path, package_atom) do
              {:ok, :removed} ->
                Mix.shell().info("  ✓ Removed {:#{package_atom}, ...} from #{mix_exs_path}")

              {:ok, :not_found} ->
                Mix.shell().info(
                  "  ℹ {:#{package_atom}, ...} not found in #{mix_exs_path} — skipping"
                )

              {:error, reason} ->
                Mix.shell().error("  ✗ Could not edit #{mix_exs_path}: #{reason}")
            end

            # 3. Clean compiled artifacts and unlock
            Mix.shell().info("  Running: mix deps.clean #{package_atom} --unlock")
            Mix.shell().cmd("mix deps.clean #{package_atom} --unlock")

            # 4. Re-resolve lock (drops orphaned transitive deps automatically)
            Mix.shell().info("  Running: mix deps.get")
            Mix.shell().cmd("mix deps.get")

            Mix.shell().info("""

            ✅ Plugin '#{name}' removed.
               Run `mix compile` to rebuild.
            """)
          else
            Mix.shell().info("Aborted.")
          end
        end
    end
  end

  def run(["install", name | _rest]) do
    Application.ensure_all_started(:yaml_elixir)
    manifests = Manifest.discover()

    if Enum.any?(manifests, &(&1.id == name)) do
      Mix.shell().info("""
      Plugin '#{name}' is already installed (found in priv/plugins/).
      To activate it, run:

          mix pincer.plugins enable #{name}
      """)
    else
      Mix.shell().info("""
      Plugin '#{name}' not found locally.

      To install from Hex, add to your mix.exs deps:

          {:pincer_#{name}, "~> 0.1"}

      Then run:

          mix deps.get
          mix pincer.plugins enable #{name}
      """)
    end
  end

  def run(_args) do
    Mix.shell().info("""
    Usage:
      mix pincer.plugins list                          # Lista plugins instalados
      mix pincer.plugins status   [--config p]         # Estado de todos os plugins
      mix pincer.plugins enable  <name> [--config p]   # Habilita canal no config.yaml
      mix pincer.plugins disable <name> [--config p]   # Desabilita canal no config.yaml
      mix pincer.plugins install <name>                # Instala plugin Hex
      mix pincer.plugins remove  <name> [--yes]        # Remove dep Hex + deps.clean
    """)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp print_manifest(%Manifest{} = m) do
    Mix.shell().info("  #{m.id}  (#{m.kind})  v#{m.version}  — #{m.name}")

    if m.description do
      Mix.shell().info("    #{m.description}")
    end

    Mix.shell().info("")
  end

  defp read_config_channels(config_path) do
    case File.read(config_path) do
      {:ok, content} ->
        case YamlElixir.read_from_string(content) do
          {:ok, %{"channels" => channels}} when is_map(channels) -> channels
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  # Modifies the `channels.<name>.enabled` value in a YAML text without
  # reparsing/reserialising — preserves all comments and formatting.
  @spec set_channel_enabled(String.t(), String.t(), boolean()) ::
          {:ok, String.t()} | {:error, :channel_not_found}
  defp set_channel_enabled(content, channel_name, value) do
    section_re = ~r/^  #{Regex.escape(channel_name)}:/
    enabled_re = ~r/^    enabled:/
    next_section_re = ~r/^  [a-zA-Z_]/

    lines = String.split(content, "\n")

    {result_lines, state, found_enabled} =
      Enum.reduce(lines, {[], :scanning, false}, fn line, {acc, state, found_enabled} ->
        case state do
          :scanning ->
            if Regex.match?(section_re, line) do
              {acc ++ [line], :in_section, false}
            else
              {acc ++ [line], :scanning, found_enabled}
            end

          :in_section ->
            cond do
              Regex.match?(enabled_re, line) ->
                {acc ++ ["    enabled: #{value}"], :in_section, true}

              Regex.match?(next_section_re, line) ->
                # Leaving the section — inject `enabled:` if not seen yet
                prefix =
                  if found_enabled,
                    do: acc,
                    else: acc ++ ["    enabled: #{value}"]

                {prefix ++ [line], :done, true}

              true ->
                {acc ++ [line], :in_section, found_enabled}
            end

          :done ->
            {acc ++ [line], :done, found_enabled}
        end
      end)

    cond do
      state == :scanning ->
        {:error, :channel_not_found}

      # Reached EOF while still in the section and never saw enabled: — inject it
      state == :in_section and not found_enabled ->
        {:ok, Enum.join(result_lines ++ ["    enabled: #{value}"], "\n")}

      true ->
        {:ok, Enum.join(result_lines, "\n")}
    end
  end

  # Derives the Mix app atom from a manifest, e.g. "slack" → :pincer_slack.
  # Manifests from Hex packages have the package name in their source path;
  # fall back to the conventional naming scheme.
  @spec manifest_to_package_atom(Manifest.t()) :: atom()
  defp manifest_to_package_atom(%Manifest{} = manifest) do
    # If the manifest came from a Hex dep, its file path is inside
    # _build/.../priv/pincer_plugin.yaml and we can read the app name from it.
    # For simplicity, derive it by convention: id → :pincer_<id>.
    String.to_atom("pincer_#{manifest.id}")
  end

  # Returns true when the package is declared as a path dep in this project.
  # Path deps are bundled (monorepo) packages — they cannot be Hex-removed.
  @spec path_dep?(atom()) :: boolean()
  defp path_dep?(package_atom) do
    Mix.Project.config()[:deps]
    |> List.wrap()
    |> Enum.any?(fn
      {^package_atom, opts} when is_list(opts) -> Keyword.has_key?(opts, :path)
      {^package_atom, _version, opts} when is_list(opts) -> Keyword.has_key?(opts, :path)
      _ -> false
    end)
  end

  # Removes the line declaring `{:package_atom, ...}` from mix.exs.
  # Returns {:ok, :removed}, {:ok, :not_found}, or {:error, reason}.
  @spec remove_dep_from_mix_exs(String.t(), atom()) ::
          {:ok, :removed | :not_found} | {:error, String.t()}
  defp remove_dep_from_mix_exs(mix_exs_path, package_atom) do
    dep_re = ~r/\{:#{Regex.escape(Atom.to_string(package_atom))}\b/

    case File.read(mix_exs_path) do
      {:error, reason} ->
        {:error, :file.format_error(reason)}

      {:ok, content} ->
        lines = String.split(content, "\n")
        filtered = Enum.reject(lines, &Regex.match?(dep_re, &1))

        if length(filtered) == length(lines) do
          {:ok, :not_found}
        else
          File.write!(mix_exs_path, Enum.join(filtered, "\n"))
          {:ok, :removed}
        end
    end
  end
end
