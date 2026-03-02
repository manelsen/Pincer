defmodule Mix.Tasks.Pincer.Onboard do
  @moduledoc """
  Linux-style onboarding wizard for initial Pincer setup.

  Usage:

      mix pincer.onboard
      mix pincer.onboard --non-interactive --yes
      mix pincer.onboard --non-interactive --db-path db/custom.db
      mix pincer.onboard --non-interactive --yes --capabilities workspace_dirs,config_yaml
  """

  use Mix.Task
  use Boundary, classify_to: Pincer.Mix
  alias Pincer.Core.Onboard

  @shortdoc "Initialize config and workspace files"

  @switches [
    non_interactive: :boolean,
    yes: :boolean,
    db_path: :string,
    provider: :string,
    model: :string,
    capabilities: :string,
    mode: :string,
    remote_host: :string,
    remote_user: :string,
    remote_path: :string
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches, aliases: [y: :yes])

    if invalid != [] do
      invalid_flags = Enum.map_join(invalid, ", ", fn {k, _} -> "--#{k}" end)
      Mix.raise("Invalid flags for pincer.onboard: #{invalid_flags}")
    end

    mode = parse_mode!(opts[:mode])
    base_config = resolve_base_config(Onboard.defaults())
    onboarding_config = resolve_config(base_config, opts)

    capabilities = parse_capabilities(opts[:capabilities])
    validate_option_matrix!(opts, capabilities)
    run_preflight!(onboarding_config)

    case mode do
      :local ->
        force? = resolve_force?(opts)
        apply_local_plan!(onboarding_config, capabilities, force?)

      :remote ->
        run_remote_assisted!(onboarding_config, opts, capabilities || [])
    end
  end

  defp resolve_config(config, opts) do
    if opts[:non_interactive] do
      apply_overrides(config, opts)
    else
      ask_interactive(config, opts)
    end
  end

  defp resolve_base_config(defaults) do
    if File.exists?("config.yaml") do
      case YamlElixir.read_from_file("config.yaml") do
        {:ok, existing} when is_map(existing) ->
          Onboard.merge_config(defaults, existing)

        {:ok, _other} ->
          Mix.raise("Invalid existing config.yaml format. Hint: root element must be a YAML map.")

        {:error, reason} ->
          Mix.raise(
            "Could not read existing config.yaml: #{inspect(reason)}. Hint: fix YAML syntax or remove the file."
          )
      end
    else
      defaults
    end
  end

  defp ask_interactive(config, opts) do
    Mix.shell().info("Pincer onboarding wizard")
    Mix.shell().info("Press ENTER to keep defaults.")

    db_default = opts[:db_path] || get_in(config, ["database", "database"])
    provider_default = opts[:provider] || get_in(config, ["llm", "provider"])
    model_default = opts[:model] || get_in(config, ["llm", provider_default, "default_model"])

    db_path = prompt_with_default("Database path", db_default)
    provider = prompt_with_default("LLM provider", provider_default)
    model = prompt_with_default("Default model", model_default)

    apply_overrides(config, db_path: db_path, provider: provider, model: model)
  end

  defp prompt_with_default(label, default) do
    answer =
      Mix.shell()
      |> then(& &1.prompt("#{label} [#{default}]: "))
      |> to_string()
      |> String.trim()

    if answer == "", do: default, else: answer
  end

  defp apply_overrides(config, opts) do
    db_path = opts[:db_path] || get_in(config, ["database", "database"])
    provider = opts[:provider] || get_in(config, ["llm", "provider"])

    model =
      opts[:model] ||
        get_in(config, ["llm", provider, "default_model"]) ||
        get_in(config, ["llm", get_in(config, ["llm", "provider"]), "default_model"])

    config
    |> put_in(["database", "database"], db_path)
    |> put_in(["llm", "provider"], provider)
    |> ensure_provider_model(provider, model)
  end

  defp ensure_provider_model(config, provider, model) do
    llm = config["llm"]

    provider_config =
      Map.get(llm, provider, %{
        "base_url" => "https://api.example.com/v1/chat/completions",
        "default_model" => model
      })
      |> Map.put("default_model", model)

    put_in(config, ["llm"], Map.put(llm, provider, provider_config))
  end

  defp resolve_force?(opts) do
    cond do
      opts[:yes] ->
        true

      opts[:non_interactive] ->
        false

      File.exists?("config.yaml") ->
        answer =
          Mix.shell()
          |> then(& &1.prompt("config.yaml already exists. Overwrite? [y/N]: "))
          |> to_string()
          |> String.trim()
          |> String.downcase()

        answer in ["y", "yes"]

      true ->
        false
    end
  end

  defp print_summary(report) do
    Mix.shell().info("")
    Mix.shell().info("Pincer onboarding complete.")
    Mix.shell().info("Created: #{format_paths(report.created)}")
    Mix.shell().info("Written: #{format_paths(report.written)}")
    Mix.shell().info("Skipped: #{format_paths(report.skipped)}")
    Mix.shell().info("")
    Mix.shell().info("Next steps:")
    Mix.shell().info("1) Review config.yaml and set provider credentials in .env")
    Mix.shell().info("2) Start with: mix pincer.chat")

    Mix.shell().info(
      "3) WhatsApp bridge (optional): npm install --prefix infrastructure/whatsapp"
    )

    Mix.shell().info("4) To enable WhatsApp, set channels.whatsapp.enabled=true in config.yaml")

    Mix.shell().info(
      "5) Pairing flow: WhatsApp Mobile -> Aparelhos conectados -> Conectar um aparelho (scan terminal QR)"
    )
  end

  defp parse_mode!(nil), do: :local

  defp parse_mode!(mode) when is_binary(mode) do
    case mode |> String.trim() |> String.downcase() do
      "local" -> :local
      "remote" -> :remote
      other -> Mix.raise("Invalid onboarding mode: #{other}. Valid values: local, remote")
    end
  end

  defp format_paths([]), do: "-"
  defp format_paths(paths), do: Enum.join(paths, ", ")

  defp parse_capabilities(nil), do: nil

  defp parse_capabilities(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp validate_option_matrix!(opts, capabilities) do
    if is_list(capabilities) and "config_yaml" not in capabilities do
      invalid_flag =
        [:db_path, :provider, :model]
        |> Enum.find(&present_option?(opts, &1))

      if invalid_flag do
        flag_name = "--#{invalid_flag |> to_string() |> String.replace("_", "-")}"

        Mix.raise(
          "#{flag_name} requires config_yaml capability when --capabilities is explicitly set."
        )
      end
    end
  end

  defp present_option?(opts, key) do
    case opts[key] do
      nil -> false
      value when is_binary(value) -> String.trim(value) != ""
      _ -> true
    end
  end

  defp run_preflight!(config) do
    case Onboard.preflight(config) do
      :ok ->
        :ok

      {:error, issues} ->
        details =
          Enum.map_join(issues, "\n", fn issue ->
            "- #{issue.id}: #{issue.message}. Hint: #{issue.hint}"
          end)

        Mix.raise("Onboarding preflight failed:\n#{details}")
    end
  end

  defp apply_local_plan!(onboarding_config, capabilities, force?) do
    plan =
      case Onboard.plan(onboarding_config, capabilities: capabilities) do
        {:ok, operations} ->
          operations

        {:error, {:unknown_capabilities, unknown}} ->
          valid = Enum.join(Onboard.available_capabilities(), ", ")
          invalid = Enum.join(unknown, ", ")

          Mix.raise("Invalid onboarding capabilities: #{invalid}. Valid values: #{valid}")
      end

    case Onboard.apply_plan(plan, root: File.cwd!(), force: force?) do
      {:ok, report} ->
        print_summary(report)
        :ok

      {:error, reason} ->
        Mix.raise("Onboarding failed: #{inspect(reason)}")
    end
  end

  defp run_remote_assisted!(onboarding_config, opts, capabilities) do
    remote_host = opts[:remote_host]
    remote_user = opts[:remote_user]
    remote_path = opts[:remote_path]

    if not present_option?(opts, :remote_host) do
      Mix.raise("--remote-host is required when --mode remote.")
    end

    report = Onboard.assisted_preflight(onboarding_config)
    print_assisted_preflight(report)

    case Onboard.remote_assisted_plan(onboarding_config,
           remote_host: remote_host,
           remote_user: remote_user,
           remote_path: remote_path,
           capabilities: capabilities
         ) do
      {:ok, plan} ->
        print_remote_plan(plan)
        :ok

      {:error, issue} ->
        Mix.raise("Remote onboarding plan failed: #{issue.message}. Hint: #{issue.hint}")
    end
  end

  defp print_assisted_preflight(report) do
    Mix.shell().info("")
    Mix.shell().info("Assisted environment checklist")

    Enum.each(report.checks, fn check ->
      level = check.severity |> to_string() |> String.upcase()
      Mix.shell().info("[#{level}] #{format_check_id(check.id)} - #{check.message}")
      Mix.shell().info("      Hint: #{check.hint}")
    end)

    Mix.shell().info("Checklist status: #{report.status}")
  end

  defp print_remote_plan(plan) do
    Mix.shell().info("")
    Mix.shell().info("Remote assisted onboarding plan")
    Mix.shell().info("Target: #{plan.target}")
    Mix.shell().info("Path: #{plan.project_path}")
    Mix.shell().info("Onboard command: #{plan.onboard_command}")
    Mix.shell().info("")
    Mix.shell().info("Suggested execution steps:")

    plan.steps
    |> Enum.with_index(1)
    |> Enum.each(fn {step, idx} ->
      Mix.shell().info("#{idx}) #{step}")
    end)
  end

  defp format_check_id({left, right}), do: "#{left}:#{right}"
  defp format_check_id(id), do: to_string(id)
end
