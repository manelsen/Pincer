defmodule Pincer.Core.Doctor do
  @moduledoc """
  Operational diagnostics for config, security and runtime readiness.

  The doctor validates local configuration without external network calls and
  returns a deterministic report suitable for CLI display or automation.
  """

  @typedoc "Diagnostic severity."
  @type severity :: :ok | :warn | :error

  @typedoc "Single diagnostic check result."
  @type check :: %{
          id: atom() | {atom(), String.t()},
          severity: severity(),
          message: String.t(),
          meta: map()
        }

  @typedoc "Doctor report."
  @type report :: %{
          status: severity(),
          counts: %{ok: non_neg_integer(), warn: non_neg_integer(), error: non_neg_integer()},
          checks: [check()],
          config_path: String.t(),
          run_id: String.t()
        }

  alias Pincer.Core.ConfigProbe
  alias Pincer.Core.Posture
  alias Pincer.Infra.SQLite
  alias Pincer.Utils.MapHelpers

  import Posture, only: [ok_check: 3, warn_check: 3, error_check: 3]

  @default_config_file "config.yaml"
  @default_sqlite_path "data/pincer.db"

  @vec_extension_candidates [
    "priv/sqlite_vec/vec0.so",
    "priv/sqlite_vec/vec0",
    "priv/sqlite_vec/vec0.dylib"
  ]

  @doc """
  Runs doctor checks and returns a structured report.

  Supported options:
  - `:root` - base directory for relative config path (default: current dir)
  - `:config_file` - config file path (default: `config.yaml`)
  - `:env_fetcher` - function `(env_key -> value)` for env lookup (default: `System.get_env/1`)
  """
  @spec run(keyword()) :: report()
  def run(opts \\ []) do
    root = Keyword.get(opts, :root, File.cwd!())
    config_file = Keyword.get(opts, :config_file, @default_config_file)
    env_fetcher = Keyword.get(opts, :env_fetcher, &System.get_env/1)
    {config_path, config, config_check} = Posture.read_config(root, config_file)

    checks =
      [config_check] ++
        storage_checks(config, root, env_fetcher) ++
        Posture.channel_token_checks(config, env_fetcher, :channel_token) ++
        Posture.dm_checks(config) ++
        llm_provider_checks(config, env_fetcher) ++
        introspection_provider_checks(config, env_fetcher) ++
        native_binary_checks(config) ++
        runtime_cohesion_checks() ++
        alignment_integrity_checks()

    Posture.report(checks, config_path, :doctor)
  end

  defp native_binary_checks(config) do
    channels(config)
    |> Enum.filter(fn {name, channel_cfg} -> name == "whatsapp" and enabled?(channel_cfg) end)
    |> Enum.flat_map(fn _ ->
      case System.find_executable("go") do
        nil ->
          [
            warn_check(
              :go_binary,
              "WhatsApp channel is enabled but `go` was not found in PATH — " <>
                "the whatsapp_bridge sidecar requires Go 1.21+ to compile",
              %{channel: "whatsapp", required_tool: "go"}
            )
          ]

        path ->
          [
            ok_check(
              :go_binary,
              "Go compiler found at #{path} (required by whatsapp_bridge sidecar)",
              %{channel: "whatsapp", go_path: path}
            )
          ]
      end
    end)
  end

  defp alignment_integrity_checks do
    alias Pincer.Core.AgentPaths
    alias Pincer.Core.Session.AlignmentIntegrity

    base = AgentPaths.base_dir()

    if File.dir?(base) do
      base
      |> File.ls!()
      |> Enum.reject(&String.starts_with?(&1, "."))
      |> Enum.filter(&File.dir?(Path.join(base, &1)))
      |> Enum.flat_map(fn agent_id ->
        workspace = AgentPaths.workspace_root(agent_id)

        case AlignmentIntegrity.verify(workspace) do
          {:ok, []} ->
            [
              ok_check(
                {:alignment, agent_id},
                "Alignment integrity OK for #{agent_id}",
                %{agent_id: agent_id}
              )
            ]

          {:ok, violations} ->
            Enum.map(violations, fn %{file: file, status: status} ->
              warn_check(
                {:alignment, agent_id},
                "#{file} #{status} in #{agent_id} — possible tamper",
                %{agent_id: agent_id, file: file, status: status}
              )
            end)

          {:error, :no_snapshot} ->
            []
        end
      end)
    else
      []
    end
  end

  defp storage_checks(config, root, env_fetcher) do
    case SQLite.resolve_storage_backend(
           env_fetcher.("PINCER_STORAGE"),
           read_sub(config["storage"], :adapter)
         ) do
      {:ok, :sqlite} ->
        [ok_check(:storage_backend, "Storage backend configured: sqlite", %{backend: :sqlite})] ++
          sqlite_storage_checks(config, root, env_fetcher) ++ sqlite_vec_checks(config)

      {:error, {:unsupported_storage_backend, backend}} ->
        [
          error_check(
            :storage_backend,
            "Unsupported storage backend: #{inspect(backend)}. Only embedded SQLite is supported.",
            %{backend: backend}
          )
        ]
    end
  end

  defp sqlite_storage_checks(config, root, env_fetcher) do
    path = resolve_sqlite_path_for_doctor(config, env_fetcher)

    path_check =
      case SQLite.check_writable_path(path, root: root) do
        :ok ->
          ok_check(:sqlite_path, "SQLite database path is writable (#{path})", %{path: path})

        {:error, reason} ->
          error_check(
            :sqlite_path,
            "Invalid or unwritable SQLite path '#{path}': #{inspect(reason)}",
            %{path: path, reason: reason}
          )
      end

    engine_check =
      case SQLite.health_check() do
        :ok ->
          ok_check(:sqlite_engine, "Embedded SQLite3 + FTS5 engine operational", %{})

        {:error, reason} ->
          error_check(
            :sqlite_engine,
            "Embedded SQLite3 engine check failed: #{inspect(reason)}",
            %{reason: inspect(reason)}
          )
      end

    [path_check, engine_check]
  end

  defp sqlite_vec_checks(config) do
    storage_cfg = MapHelpers.read_field(config, :storage)
    setting = read_sub(storage_cfg, :vec)
    explicit_path = read_sub(storage_cfg, :vec_path)

    cond do
      vec_disabled?(setting) ->
        [
          ok_check(
            :sqlite_vec,
            "SQLite vector extension disabled; semantic search will use cosine fallback",
            %{enabled: false, reason: :disabled}
          )
        ]

      vec_extension_available?(explicit_path, setting) ->
        [
          ok_check(
            :sqlite_vec,
            "SQLite vector extension is available",
            %{enabled: true}
          )
        ]

      true ->
        [
          warn_check(
            :sqlite_vec,
            "SQLite vector extension not found; semantic search will use cosine fallback",
            %{enabled: false, reason: :missing_extension}
          )
        ]
    end
  end

  defp vec_disabled?(false), do: true
  defp vec_disabled?(0), do: true

  defp vec_disabled?(value) when is_binary(value) do
    String.downcase(String.trim(value)) in ["false", "off", "disabled", "none"]
  end

  defp vec_disabled?(_value), do: false

  defp vec_extension_available?(explicit_path, setting) do
    path =
      normalize_path(explicit_path) ||
        normalize_path(System.get_env("PINCER_SQLITE_VEC_PATH")) ||
        normalize_vec_setting_path(setting)

    case path do
      nil -> Enum.any?(default_vec_extension_paths(), &File.regular?/1)
      path -> File.regular?(path)
    end
  end

  defp normalize_vec_setting_path(value) when is_binary(value) do
    trimmed = String.trim(value)

    if String.downcase(trimmed) in [
         "",
         "auto",
         "true",
         ":auto",
         "false",
         "off",
         "disabled",
         "none"
       ] do
      nil
    else
      trimmed
    end
  end

  defp normalize_vec_setting_path(_value), do: nil

  defp normalize_path(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_path(_value), do: nil

  defp default_vec_extension_paths do
    priv_dir =
      case :code.priv_dir(:pincer) do
        path when is_list(path) -> List.to_string(path)
        _ -> nil
      end

    @vec_extension_candidates
    |> Enum.flat_map(fn relative ->
      [Path.expand(relative)] ++
        if(is_binary(priv_dir),
          do: [Path.join(priv_dir, Path.basename(relative))],
          else: []
        )
    end)
    |> Enum.uniq()
  end

  defp resolve_sqlite_path_for_doctor(config, env_fetcher) do
    storage_cfg = MapHelpers.read_field(config, :storage)

    candidates = [
      env_fetcher.("PINCER_SQLITE_PATH"),
      read_sub(storage_cfg, :path),
      @default_sqlite_path
    ]

    candidates
    |> Enum.find(fn
      val when is_binary(val) -> String.trim(val) != ""
      _ -> false
    end)
    |> String.trim()
  end

  defp read_sub(map, key) when is_map(map), do: MapHelpers.read_field(map, key)
  defp read_sub(_, _), do: nil

  defp runtime_cohesion_checks do
    [
      check_runtime(
        :policy_kernel,
        Pincer.Core.Policy,
        [allow?: 2, route: 2, budget: 2, guard!: 2, recover: 2],
        "Policy kernel facade is available"
      ),
      check_runtime(
        :trace_runtime,
        Pincer.Core.Executor.Trace,
        [new: 2, add_step: 4, to_checkpoint_metadata: 1],
        "Trace runtime is available"
      ),
      check_runtime(
        :tool_risk_runtime,
        Pincer.Core.Executor.ToolRuntime,
        [classify: 1, requires_approval?: 1, execute: 5],
        "Tool risk runtime is available"
      ),
      check_runtime(
        :memory_health,
        Pincer.Core.MemoryPipeline,
        [run: 2],
        "Unified memory pipeline is available"
      )
    ]
  end

  defp check_runtime(id, module, exports, ok_message) do
    if Code.ensure_loaded?(module) and
         Enum.all?(exports, fn {name, arity} -> function_exported?(module, name, arity) end) do
      ok_check(id, ok_message, %{module: inspect(module), exports: exports})
    else
      warn_check(
        id,
        "Missing runtime exports for #{inspect(module)}",
        %{
          module: inspect(module),
          expected_exports: exports
        }
      )
    end
  end

  defp llm_provider_checks(config, env_fetcher) do
    registry = Application.get_env(:pincer, :llm_providers)

    check_configured_provider(
      :llm_provider,
      ConfigProbe.provider_env(config, registry, env_fetcher)
    )
  end

  defp introspection_provider_checks(config, env_fetcher) do
    intro_cfg = MapHelpers.read_field(config, :introspection)
    provider = read_sub(intro_cfg, :provider)
    model = read_sub(intro_cfg, :model)
    locality = read_sub(intro_cfg, :locality)

    cond do
      not MapHelpers.present?(provider) ->
        [
          ok_check(
            :introspection_provider,
            "Introspection inherits active session or default LLM provider",
            %{provider: :inherited, locality: locality || "default"}
          )
        ]

      Pincer.Core.Introspection.Client.local_provider?(provider, intro_cfg) ->
        [
          ok_check(
            {:introspection_provider, to_string(provider)},
            "Introspection provider '#{provider}' runs locally (model: #{model || "default"})",
            %{provider: provider, model: model, locality: :local}
          )
        ]

      true ->
        registry = Application.get_env(:pincer, :llm_providers)
        synthetic_cfg = %{"llm" => %{"provider" => provider}}

        check_configured_provider(
          :introspection_provider,
          ConfigProbe.provider_env(synthetic_cfg, registry, env_fetcher),
          %{model: model, locality: locality || "default"}
        )
    end
  end

  defp check_configured_provider(id_tag, result, extra_meta \\ %{})
  defp check_configured_provider(_id_tag, nil, _extra_meta), do: []

  defp check_configured_provider(id_tag, {provider, nil, :unregistered}, extra_meta) do
    [
      warn_check(
        {id_tag, provider},
        "Active #{provider_label(id_tag)} provider '#{provider}' is not registered in :llm_providers",
        Map.put(extra_meta, :provider, provider)
      )
    ]
  end

  defp check_configured_provider(id_tag, {provider, nil, :not_required}, extra_meta) do
    [
      ok_check(
        {id_tag, provider},
        "Provider '#{provider}' does not require an API key",
        Map.put(extra_meta, :provider, provider)
      )
    ]
  end

  defp check_configured_provider(id_tag, {provider, nil, :invalid_auth_config}, extra_meta) do
    [
      error_check(
        {id_tag, provider},
        "Provider '#{provider}' declares an auth chain without a usable environment key",
        Map.put(extra_meta, :provider, provider)
      )
    ]
  end

  defp check_configured_provider(id_tag, {provider, key, :present}, extra_meta) do
    [
      ok_check(
        {id_tag, provider},
        "Provider '#{provider}' configurado (#{key} presente)",
        Map.merge(extra_meta, %{provider: provider, env_key: key})
      )
    ]
  end

  defp check_configured_provider(id_tag, {provider, key, :missing_value}, extra_meta) do
    [
      error_check(
        {id_tag, provider},
        "Provider '#{provider}' ativo mas #{key} nao esta definido",
        Map.merge(extra_meta, %{provider: provider, env_key: key})
      )
    ]
  end

  defp provider_label(:introspection_provider), do: "introspection"
  defp provider_label(_), do: "LLM"

  defp channels(config), do: ConfigProbe.channels(config)
  defp enabled?(cfg), do: ConfigProbe.enabled?(cfg)
end
