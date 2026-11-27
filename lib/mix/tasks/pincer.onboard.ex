defmodule Mix.Tasks.Pincer.Onboard do
  @moduledoc """
  Linux-style onboarding wizard for initial Pincer setup.

  Usage:

      mix pincer.onboard
      mix pincer.onboard --non-interactive --yes
      mix pincer.onboard --non-interactive --yes --sqlite-path data/pincer.db
      mix pincer.onboard --non-interactive --yes --capabilities workspace_dirs,config_yaml
  """

  use Mix.Task
  use Boundary, classify_to: Pincer.Mix
  alias Pincer.Core.AgentPaths
  alias Pincer.Core.Onboard
  alias Pincer.Core.Onboard.Defaults
  alias Pincer.Infra.SQLite

  @shortdoc "Initialize config and workspace files"

  @security_warning """
  ⚠️  SECURITY WARNING — read before continuing.

  Pincer is a project under development. With tools enabled, the agent
  can read files, execute commands, and make HTTP requests.
  A malicious prompt may induce unintended actions.

  Minimum recommendations:
  - Enable only the tools you need.
  - Do not leave secrets in files accessible to the agent.
  - In multi-user environments, use isolated sessions per user.
  - Run regularly: mix pincer.security_audit
  """

  @switches [
    non_interactive: :boolean,
    yes: :boolean,
    if_missing: :boolean,
    accept_risk: :boolean,
    config: :string,
    root: :string,
    storage: :string,
    sqlite_path: :string,
    provider: :string,
    model: :string,
    capabilities: :string,
    mode: :string,
    remote_host: :string,
    remote_user: :string,
    remote_path: :string,
    api_key: :string
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches, aliases: [y: :yes])

    if invalid != [] do
      invalid_flags = Enum.map_join(invalid, ", ", fn {k, _} -> "--#{k}" end)
      Mix.raise("Invalid flags for pincer.onboard: #{invalid_flags}")
    end

    root = resolve_root(opts[:root])
    config_file = resolve_config_file(root, opts[:config])

    if opts[:if_missing] && Onboard.onboarded?(root) && File.exists?(config_file) do
      Mix.shell().info("Workspace already onboarded. Skipping.")
      :ok
    else
      do_run(opts, root, config_file)
    end
  end

  defp resolve_root(nil), do: File.cwd!()
  defp resolve_root(root) when is_binary(root), do: Path.expand(root)

  defp resolve_config_file(root, nil), do: Path.join(root, "config.yaml")
  defp resolve_config_file(root, config_file), do: Path.expand(config_file, root)

  defp do_run(opts, root, config_file) do
    require_risk_acknowledgement(opts)

    mode = parse_mode!(opts[:mode])
    parse_storage_opt!(opts[:storage])
    base_config = resolve_base_config(config_file)
    onboarding_config = resolve_config(base_config, opts)
    maybe_capture_api_key(onboarding_config, opts, root)

    capabilities = parse_capabilities(opts[:capabilities])
    validate_option_matrix!(opts, capabilities)
    run_preflight!(onboarding_config)

    case mode do
      :local ->
        force? = resolve_force?(opts, config_file)
        apply_local_plan!(onboarding_config, capabilities, force?, config_file, root)

      :remote ->
        run_remote_assisted!(onboarding_config, opts, capabilities || [])
    end
  end

  defp require_risk_acknowledgement(opts) do
    cond do
      opts[:accept_risk] ->
        :ok

      opts[:non_interactive] ->
        Mix.shell().info(@security_warning)
        :ok

      true ->
        Mix.shell().info(@security_warning)

        answer =
          Mix.shell()
          |> then(& &1.prompt("Understood? [y/N]: "))
          |> to_string()
          |> String.trim()
          |> String.downcase()

        if answer not in ["y", "yes"] do
          Mix.raise("Onboarding aborted by user.")
        end

        :ok
    end
  end

  defp resolve_config(config, opts) do
    if opts[:non_interactive] do
      apply_overrides(config, opts)
    else
      ask_interactive(config, opts)
    end
  end

  defp resolve_base_config(config_file) do
    if File.exists?(config_file) do
      case YamlElixir.read_from_file(config_file) do
        {:ok, existing} when is_map(existing) ->
          Onboard.defaults()
          |> Onboard.merge_config(existing)

        {:ok, _other} ->
          Mix.raise(
            "Invalid existing #{config_file} format. Hint: root element must be a YAML map."
          )

        {:error, reason} ->
          Mix.raise(
            "Could not read existing #{config_file}: #{inspect(reason)}. Hint: fix YAML syntax or remove the file."
          )
      end
    else
      Onboard.defaults()
    end
  end

  defp parse_storage_opt!(nil), do: :sqlite

  defp parse_storage_opt!(value) do
    case SQLite.parse_storage_backend(value) do
      {:ok, :sqlite} ->
        :sqlite

      _ ->
        Mix.raise("Invalid storage backend: #{inspect(value)}. Valid values: sqlite")
    end
  end

  defp ask_interactive(config, opts) do
    Mix.shell().info("Pincer onboarding wizard")
    Mix.shell().info("Press ENTER to keep defaults.")

    default_path = opts[:sqlite_path] || Defaults.sqlite_path(config)
    sqlite_path = prompt_with_default("SQLite database path", default_path)

    provider_default = opts[:provider] || get_in(config, ["llm", "provider"])

    provider =
      if opts[:provider] do
        opts[:provider]
      else
        prompt_provider_choice(provider_default)
      end

    model =
      if opts[:model] do
        opts[:model]
      else
        prompt_model_for_provider(provider)
      end

    apply_overrides(
      config,
      sqlite_path: sqlite_path,
      provider: provider,
      model: model
    )
  end

  defp prompt_provider_choice(_default) do
    Mix.shell().info("\nSelect LLM provider:")
    Mix.shell().info("  1) openrouter      (OpenRouter — access to multiple models)")
    Mix.shell().info("  2) groq            (Groq — ultra fast inference)")
    Mix.shell().info("  3) anthropic       (Claude 5.5 / Fable 5.2)")
    Mix.shell().info("  4) google          (Google Gemini 4 / 3.8 Flash)")
    Mix.shell().info("  5) openai          (OpenAI GPT-6.2)")
    Mix.shell().info("  6) z_ai            (Z.AI / Zhipu GLM-5)")
    Mix.shell().info("  7) deepseek        (DeepSeek V4)")
    Mix.shell().info("  8) qwen            (Alibaba DashScope Qwen 3.6/3.7)")
    Mix.shell().info("  9) moonshot        (Moonshot / Kimi K3)")
    Mix.shell().info(" 10) mistral         (Mistral Large/Small 4)")
    Mix.shell().info(" 11) minimax         (MiniMax M3)")
    Mix.shell().info(" 12) ollama          (Ollama — local models)")
    Mix.shell().info(" 13) opencode_zen    (OpenCode Zen — Kimi free)")
    Mix.shell().info(" 14) Other (type ID)")

    answer = Mix.shell().prompt("Choose [1-14]: ") |> to_string() |> String.trim()

    case answer do
      "1" -> "openrouter"
      "2" -> "groq"
      "3" -> "anthropic"
      "4" -> "google"
      "5" -> "openai"
      "6" -> "z_ai"
      "7" -> "deepseek"
      "8" -> "qwen"
      "9" -> "moonshot"
      "10" -> "mistral"
      "11" -> "minimax"
      "12" -> "ollama"
      "13" -> "opencode_zen"
      "14" -> prompt_with_default("Enter provider_id", "openrouter")
      _ -> "openrouter"
    end
  end

  defp prompt_model_for_provider(provider) do
    case provider do
      "openrouter" ->
        Mix.shell().info("\nRecommended models for openrouter:")
        Mix.shell().info("  1) openrouter/free (auto-router default)")
        Mix.shell().info("  2) google/gemma-4-31b-it:free")
        Mix.shell().info("  3) anthropic/claude-sonnet-5-5")
        Mix.shell().info("  4) google/gemini-3.8-flash")
        Mix.shell().info("  5) Other (type ID)")

        case Mix.shell().prompt("Choose [1-5]: ") |> to_string() |> String.trim() do
          "1" -> "openrouter/free"
          "2" -> "google/gemma-4-31b-it:free"
          "3" -> "anthropic/claude-sonnet-5-5"
          "4" -> "google/gemini-3.8-flash"
          "5" -> prompt_with_default("Enter model_id", "openrouter/free")
          _ -> "openrouter/free"
        end

      _ ->
        prompt_with_default("Default model for #{provider}", Defaults.recommended_model(provider))
    end
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
    provider = opts[:provider] || get_in(config, ["llm", "provider"])

    model =
      opts[:model] ||
        get_in(config, ["llm", provider, "default_model"]) ||
        get_in(config, ["llm", get_in(config, ["llm", "provider"]), "default_model"])

    sqlite_path = opts[:sqlite_path] || Defaults.sqlite_path(config)

    storage =
      config
      |> Map.get("storage", %{})
      |> Map.merge(%{"adapter" => "sqlite", "path" => sqlite_path})
      |> Map.put_new("vec", "auto")

    config =
      config
      |> Map.delete("database")
      |> Map.put("storage", storage)
      |> Map.put_new("sandbox", %{"adapter" => "local"})

    config
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

  defp resolve_force?(opts, config_file) do
    cond do
      opts[:yes] ->
        true

      opts[:non_interactive] ->
        false

      File.exists?(config_file) ->
        answer =
          Mix.shell()
          |> then(& &1.prompt("#{config_file} already exists. Overwrite? [y/N]: "))
          |> to_string()
          |> String.trim()
          |> String.downcase()

        answer in ["y", "yes"]

      true ->
        false
    end
  end

  defp print_summary(report, _config, config_file) do
    Mix.shell().info("")
    Mix.shell().info("Pincer onboarding complete.")
    Mix.shell().info("Created: #{format_paths(report.created)}")
    Mix.shell().info("Written: #{format_paths(report.written)}")
    Mix.shell().info("Skipped: #{format_paths(report.skipped)}")
    Mix.shell().info("")
    Mix.shell().info("Next steps:")
    Mix.shell().info("1) Review #{config_file} and set provider credentials in .env")

    Mix.shell().info(
      "2) Start in Zero-Infra SQLite mode with: PINCER_STORAGE=sqlite mix pincer.chat"
    )

    Mix.shell().info(
      "3) WhatsApp bridge (optional): add {:pincer_whatsapp, \"~> 0.1\"} to mix.exs — the Go sidecar compiles automatically during `mix deps.compile` (requires Go 1.21+)"
    )

    Mix.shell().info(
      "4) To enable WhatsApp, set channels.whatsapp.enabled=true in #{config_file}"
    )

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
        [:provider, :model, :storage, :sqlite_path]
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

  defp apply_local_plan!(onboarding_config, capabilities, force?, config_file, root) do
    workspaces_dir = Path.expand(AgentPaths.base_dir(), root)

    plan =
      case Onboard.plan(onboarding_config,
             capabilities: capabilities,
             config_file: config_file,
             workspaces_dir: workspaces_dir
           ) do
        {:ok, operations} ->
          operations

        {:error, {:unknown_capabilities, unknown}} ->
          valid = Enum.join(Onboard.available_capabilities(), ", ")
          invalid = Enum.join(unknown, ", ")

          Mix.raise("Invalid onboarding capabilities: #{invalid}. Valid values: #{valid}")
      end

    case Onboard.apply_plan(plan, root: root, force: force?) do
      {:ok, report} ->
        print_summary(report, onboarding_config, config_file)
        check_db_connectivity(onboarding_config)
        run_doctor_report(onboarding_config, config_file, root)
        :ok

      {:error, reason} ->
        Mix.raise("Onboarding failed: #{inspect(reason)}")
    end
  end

  defp check_db_connectivity(config) do
    case Onboard.check_db_connectivity(config) do
      :ok ->
        Mix.shell().info("  ✓ SQLite embutido operacional")

      {:warn, message} ->
        Mix.shell().info("")
        Mix.shell().info("⚠  #{message}")
    end
  end

  defp run_doctor_report(_config, config_path, root) do
    if File.exists?(config_path) do
      Mix.shell().info("")
      Mix.shell().info("─── Relatório de saúde pós-configuração ─────────────────────")

      report = Pincer.Core.Doctor.run(config_file: config_path, root: root)

      Enum.each(report.checks, fn check ->
        icon =
          case check.severity do
            :ok -> "✓"
            :warn -> "⚠"
            :error -> "✗"
          end

        Mix.shell().info("  [#{icon}] #{format_check_id(check.id)} — #{check.message}")
      end)

      Mix.shell().info("")

      case report.status do
        :ok ->
          Mix.shell().info("✅ Pronto. Execute: mix pincer.chat")

        :warn ->
          Mix.shell().info(
            "⚠  Configuração completa com avisos. Revise os itens acima antes de iniciar."
          )

          Mix.shell().info("   Execute: mix pincer.chat")

        :error ->
          Mix.shell().info(
            "✗  Há erros de configuração. Corrija os itens acima antes de iniciar."
          )

          Mix.shell().info("   Re-execute: mix pincer.doctor para diagnóstico completo.")
      end
    else
      Mix.shell().info("\n✅ Pronto. Execute: mix pincer.chat")
    end
  end

  defp format_check_id({left, right}), do: "#{left}:#{right}"
  defp format_check_id(id), do: to_string(id)

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

  defp maybe_capture_api_key(config, opts, root) do
    env_file = Path.join(root, ".env")
    provider = get_in(config, ["llm", "provider"])
    env_key = Pincer.Core.Onboard.Defaults.provider_env_key(provider)

    cond do
      opts[:non_interactive] ->
        api_key = opts[:api_key]

        if api_key && env_key do
          write_env_key(env_file, env_key, api_key, root)
          System.put_env(env_key, api_key)
          Mix.shell().info("  ✓ #{env_key} escrito em .env")
        end

      env_key && System.get_env(env_key) in [nil, ""] ->
        Mix.shell().info("")
        Mix.shell().info("O provider '#{provider}' requer a variável #{env_key}.")
        answer = Mix.shell().prompt("  Cole sua chave (Enter para pular): ")
        key = String.trim(answer)

        if key != "" do
          write_env_key(env_file, env_key, key, root)
          System.put_env(env_key, key)
          Mix.shell().info("  ✓ #{env_key} escrito em .env")
        else
          Mix.shell().info(
            "  ⚠ Pulado. Lembre-se de definir #{env_key} no .env antes de iniciar."
          )
        end

      true ->
        :ok
    end

    config
  end

  defp write_env_key(path, key, value, root) do
    content =
      case File.read(path) do
        {:ok, c} ->
          c

        {:error, _} ->
          case File.read(Path.join(root, ".env.example")) do
            {:ok, c} -> c
            {:error, _} -> ""
          end
      end

    key_re = ~r/^#{Regex.escape(key)}=.*/m

    updated =
      if Regex.match?(key_re, content) do
        Regex.replace(key_re, content, "#{key}=#{value}")
      else
        content = if String.ends_with?(content, "\n"), do: content, else: content <> "\n"
        content <> "#{key}=#{value}\n"
      end

    File.write!(path, updated)
  end
end
