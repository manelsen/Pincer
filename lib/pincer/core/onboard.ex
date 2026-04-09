defmodule Pincer.Core.Onboard do
  @moduledoc """
  Core onboarding workflow for first-run setup.

  This module is intentionally channel/provider agnostic: it only defines
  defaults, file operations, and deterministic execution of an onboarding plan.
  CLI and other surfaces should call this module as an adapter boundary.
  """

  @behaviour Pincer.Ports.Onboarding
  alias Pincer.Core.Onboard.Defaults
  alias Pincer.Core.Onboard.Preflight
  alias Pincer.Utils.MapHelpers

  @channels_requiring_token MapSet.new(["telegram", "discord", "slack"])

  @typedoc "Onboarding file operation."
  @type operation ::
          {:mkdir_p, String.t()}
          | {:write_if_missing, String.t(), String.t()}
          | {:write_config_yaml, String.t(), map()}

  @typedoc "Onboarding capability ID."
  @type capability_id :: String.t()

  @typedoc "Execution summary for applied operations."
  @type report :: %{
          created: [String.t()],
          written: [String.t()],
          skipped: [String.t()]
        }

  @typedoc "Preflight validation issue."
  @type preflight_issue :: %{
          id: atom(),
          message: String.t(),
          hint: String.t()
        }

  @typedoc "Assisted preflight check severity."
  @type assisted_severity :: :ok | :warn

  @typedoc "Assisted preflight check result."
  @type assisted_check :: %{
          id: atom() | {atom(), String.t()},
          severity: assisted_severity(),
          message: String.t(),
          hint: String.t(),
          meta: map()
        }

  @typedoc "Assisted preflight report."
  @type assisted_report :: %{
          status: assisted_severity(),
          checks: [assisted_check()]
        }

  @typedoc "Remote assisted onboarding plan."
  @type remote_assisted_plan :: %{
          target: String.t(),
          project_path: String.t(),
          onboard_command: String.t(),
          steps: [String.t()]
        }

  @doc """
  Returns whether the workspace already contains the minimum onboarding scaffold.
  """
  @spec onboarded?(String.t()) :: boolean()
  def onboarded?(root \\ File.cwd!()) when is_binary(root) do
    Enum.all?(Defaults.required_paths(), fn rel_path ->
      root
      |> Path.join(rel_path)
      |> File.exists?()
    end)
  end

  @doc """
  Returns onboarding defaults used for `config.yaml` generation.
  """
  @spec defaults() :: map()
  def defaults, do: Defaults.defaults()

  @doc """
  Returns the minimum paths required for a workspace to be considered onboarded.
  """
  @spec required_paths() :: [String.t()]
  def required_paths, do: Defaults.required_paths()

  @doc """
  Builds the deterministic onboarding plan from configuration values.
  """
  @spec plan(map()) :: [operation()]
  def plan(config) when is_map(config) do
    case plan(config, capabilities: Defaults.available_capabilities()) do
      {:ok, operations} -> operations
      {:error, _reason} -> []
    end
  end

  @doc """
  Builds a deterministic onboarding plan constrained by selected capabilities.

  When no `:capabilities` option is provided, all capabilities are used.
  """
  @spec plan(map(), keyword()) ::
          {:ok, [operation()]} | {:error, {:unknown_capabilities, [String.t()]}}
  def plan(config, opts) when is_map(config) and is_list(opts) do
    capabilities =
      opts
      |> Keyword.get(:capabilities)
      |> Defaults.normalize_capabilities()

    unknown =
      capabilities
      |> Enum.uniq()
      |> Enum.reject(&(&1 in Defaults.available_capabilities()))

    if unknown == [] do
      operations =
        capabilities
        |> Enum.uniq()
        |> Enum.flat_map(&Defaults.capability_operations(&1, config))

      {:ok, operations}
    else
      {:error, {:unknown_capabilities, unknown}}
    end
  end

  @doc """
  Returns onboarding capabilities supported by the core planner.
  """
  @spec available_capabilities() :: [capability_id()]
  def available_capabilities, do: Defaults.available_capabilities()

  @doc """
  Runs onboarding preflight checks and returns actionable hints on failure.
  """
  @spec preflight(map()) :: :ok | {:error, [preflight_issue()]}
  def preflight(config) when is_map(config), do: Preflight.preflight(config)

  @doc """
  Attempts a raw TCP connection to the configured PostgreSQL host/port.
  Returns :ok or {:warn, message} — never blocks onboard, just warns.
  """
  @spec check_db_connectivity(map()) :: :ok | {:warn, String.t()}
  def check_db_connectivity(config) when is_map(config),
    do: Preflight.check_db_connectivity(config)

  @doc """
  Runs an expanded environment checklist for assisted onboarding flows.

  This checklist is non-blocking and returns warnings with remediation hints.
  """
  @spec assisted_preflight(map(), keyword()) :: assisted_report()
  def assisted_preflight(config, opts \\ []) when is_map(config) and is_list(opts) do
    env_fetcher = Keyword.get(opts, :env_fetcher, &System.get_env/1)
    command_checker = Keyword.get(opts, :command_checker, &command_available?/1)

    llm_providers =
      Keyword.get(opts, :llm_providers, Application.get_env(:pincer, :llm_providers, %{}))

    checks =
      channel_token_checks(config, env_fetcher) ++
        provider_env_checks(config, llm_providers, env_fetcher) ++
        mcp_command_checks(config, command_checker)

    status = if Enum.any?(checks, &(&1.severity == :warn)), do: :warn, else: :ok

    %{
      status: status,
      checks: checks
    }
  end

  @doc """
  Builds a deterministic remote-assisted onboarding plan.
  """
  @spec remote_assisted_plan(map(), keyword()) ::
          {:ok, remote_assisted_plan()} | {:error, preflight_issue()}
  def remote_assisted_plan(config, opts \\ []) when is_map(config) and is_list(opts) do
    remote_host = opts |> Keyword.get(:remote_host) |> normalize_string()

    remote_user =
      opts |> Keyword.get(:remote_user, System.get_env("USER") || "root") |> normalize_string()

    remote_path = opts |> Keyword.get(:remote_path, "/srv/pincer") |> normalize_string()

    capabilities =
      opts
      |> Keyword.get(:capabilities, [])
      |> Defaults.normalize_remote_capabilities()

    with :ok <- validate_remote_host(remote_host),
         :ok <- validate_remote_path(remote_path) do
      target = "#{remote_user || "root"}@#{remote_host}"
      onboard_command = build_remote_onboard_command(config, capabilities)

      {:ok,
       %{
         target: target,
         project_path: remote_path,
         onboard_command: onboard_command,
         steps: [
           "ssh #{target} \"mkdir -p #{shell_quote(remote_path)}\"",
           "ssh #{target} \"cd #{shell_quote(remote_path)} && MIX_ENV=prod mix deps.get && MIX_ENV=prod mix compile\"",
           "ssh #{target} \"cd #{shell_quote(remote_path)} && #{onboard_command}\""
         ]
       }}
    end
  end

  @doc """
  Deep merges onboarding maps.

  Values from `overrides` take precedence while keeping unknown existing keys.
  """
  @spec merge_config(map(), map()) :: map()
  def merge_config(base, overrides) when is_map(base) and is_map(overrides) do
    deep_merge(base, overrides)
  end

  @doc """
  Applies onboarding operations under `root`.

  Options:
  - `:root` workspace path (default: current directory)
  - `:force` overwrite existing files when true
  """
  @spec apply_plan([operation()], keyword()) :: {:ok, report()} | {:error, term()}
  def apply_plan(operations, opts \\ []) when is_list(operations) do
    root = Keyword.get(opts, :root, File.cwd!())
    force? = Keyword.get(opts, :force, false)
    initial = %{created: [], written: [], skipped: []}

    Enum.reduce_while(operations, {:ok, initial}, fn op, {:ok, report} ->
      case apply_operation(op, root, force?) do
        {:ok, :created, path} ->
          {:cont, {:ok, %{report | created: [path | report.created]}}}

        {:ok, :written, path} ->
          {:cont, {:ok, %{report | written: [path | report.written]}}}

        {:ok, :skipped, path} ->
          {:cont, {:ok, %{report | skipped: [path | report.skipped]}}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, report} ->
        {:ok,
         %{
           created: Enum.reverse(report.created),
           written: Enum.reverse(report.written),
           skipped: Enum.reverse(report.skipped)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp apply_operation({:mkdir_p, rel_path}, root, _force?) do
    abs_path = Path.join(root, rel_path)

    case File.mkdir_p(abs_path) do
      :ok -> {:ok, :created, rel_path}
      {:error, reason} -> {:error, {:mkdir_p, rel_path, reason}}
    end
  end

  defp apply_operation({:write_if_missing, rel_path, content}, root, force?) do
    abs_path = Path.join(root, rel_path)

    if File.exists?(abs_path) and not force? do
      {:ok, :skipped, rel_path}
    else
      case File.write(abs_path, content) do
        :ok -> {:ok, :written, rel_path}
        {:error, reason} -> {:error, {:write_if_missing, rel_path, reason}}
      end
    end
  end

  defp apply_operation({:write_config_yaml, rel_path, config}, root, force?) do
    abs_path = Path.join(root, rel_path)

    if File.exists?(abs_path) and not force? do
      {:ok, :skipped, rel_path}
    else
      case File.write(abs_path, yaml_dump(config)) do
        :ok -> {:ok, :written, rel_path}
        {:error, reason} -> {:error, {:write_config_yaml, rel_path, reason}}
      end
    end
  end

  defp channel_token_checks(config, env_fetcher) do
    config
    |> read_map_field("channels")
    |> case do
      channels when is_map(channels) ->
        channels
        |> Enum.map(fn {channel_name, channel_cfg} ->
          {normalize_channel_name(channel_name), normalize_map(channel_cfg)}
        end)
        |> Enum.filter(fn {_channel_name, channel_cfg} -> enabled_channel?(channel_cfg) end)
        |> Enum.flat_map(fn {channel_name, channel_cfg} ->
          token_env = channel_cfg |> read_map_field("token_env") |> normalize_string()

          cond do
            token_env != nil and MapHelpers.present?(env_fetcher.(token_env)) ->
              [
                assisted_ok(
                  {:channel_token, channel_name},
                  "Token env #{token_env} is present for enabled channel #{channel_name}",
                  "No action required.",
                  %{channel: channel_name, token_env: token_env}
                )
              ]

            token_env != nil ->
              [
                assisted_warn(
                  {:channel_token, channel_name},
                  "Missing token env #{token_env} for enabled channel #{channel_name}",
                  "Set #{token_env} in the target runtime environment before starting channels.",
                  %{channel: channel_name, token_env: token_env}
                )
              ]

            token_required_channel?(channel_name) ->
              [
                assisted_warn(
                  {:channel_token, channel_name},
                  "Enabled channel #{channel_name} requires token_env",
                  "Add channels.#{channel_name}.token_env to config.yaml and provide that env var.",
                  %{channel: channel_name}
                )
              ]

            true ->
              []
          end
        end)

      _ ->
        []
    end
  end

  defp provider_env_checks(config, llm_providers, env_fetcher) do
    provider =
      config
      |> get_in(["llm", "provider"])
      |> normalize_string()

    if provider == nil do
      []
    else
      provider_config = provider_registry_entry(llm_providers, provider)
      env_key = provider_config |> read_map_field("env_key") |> normalize_string()

      cond do
        env_key == nil ->
          [
            assisted_warn(
              {:provider_env, provider},
              "Provider #{provider} has no env_key metadata in registry",
              "Define env_key for provider #{provider} under :pincer, :llm_providers.",
              %{provider: provider}
            )
          ]

        MapHelpers.present?(env_fetcher.(env_key)) ->
          [
            assisted_ok(
              {:provider_env, provider},
              "Provider env #{env_key} is present",
              "No action required.",
              %{provider: provider, env_key: env_key}
            )
          ]

        true ->
          [
            assisted_warn(
              {:provider_env, provider},
              "Missing provider env #{env_key} for selected provider #{provider}",
              "Set #{env_key} in the target runtime environment.",
              %{provider: provider, env_key: env_key}
            )
          ]
      end
    end
  end

  defp mcp_command_checks(config, command_checker) do
    config
    |> get_in(["mcp", "servers"])
    |> case do
      servers when is_map(servers) ->
        servers
        |> Enum.map(fn {_server_name, server_cfg} ->
          server_cfg
          |> normalize_map()
          |> read_map_field("command")
          |> normalize_string()
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.map(fn command ->
          if command_checker.(command) do
            assisted_ok(
              {:mcp_command, command},
              "MCP command '#{command}' is available in PATH",
              "No action required.",
              %{command: command}
            )
          else
            assisted_warn(
              {:mcp_command, command},
              "MCP command '#{command}' was not found in PATH",
              "Install '#{command}' (or update mcp.servers.<name>.command) before starting MCP servers.",
              %{command: command}
            )
          end
        end)

      _ ->
        []
    end
  end

  defp validate_remote_host(nil) do
    {:error,
     %{
       id: :missing_remote_host,
       message: "remote host is missing",
       hint: "Use --remote-host <hostname-or-ip> in remote mode."
     }}
  end

  defp validate_remote_host(_host), do: :ok

  defp validate_remote_path(path) do
    cond do
      path == nil ->
        invalid_remote_path_issue()

      Path.type(path) != :absolute ->
        invalid_remote_path_issue()

      Enum.member?(Path.split(path), "..") ->
        invalid_remote_path_issue()

      true ->
        :ok
    end
  end

  defp invalid_remote_path_issue do
    {:error,
     %{
       id: :invalid_remote_path,
       message: "remote path is invalid",
       hint: "Use an absolute remote path without traversal, e.g. /srv/pincer."
     }}
  end

  defp build_remote_onboard_command(config, capabilities) do
    db_name = get_in(config, ["database", "database"]) |> normalize_string() || "pincer"
    provider = get_in(config, ["llm", "provider"]) |> normalize_string() || "z_ai"
    model = get_in(config, ["llm", provider, "default_model"]) |> normalize_string() || "glm-4.7"

    args = [
      "mix pincer.onboard",
      "--non-interactive",
      "--yes",
      "--db-name #{shell_quote(db_name)}",
      "--provider #{shell_quote(provider)}",
      "--model #{shell_quote(model)}"
    ]

    args =
      if capabilities == [] do
        args
      else
        args ++ ["--capabilities #{shell_quote(Enum.join(capabilities, ","))}"]
      end

    Enum.join(args, " ")
  end

  defp shell_quote(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\\''") <> "'"
  end

  defp command_available?(command) when is_binary(command),
    do: System.find_executable(command) != nil

  defp command_available?(_command), do: false

  defp read_map_field(map, key) when is_map(map) do
    key_text = to_string(key)

    Enum.find_value(map, fn {entry_key, entry_value} ->
      if to_string(entry_key) == key_text, do: entry_value, else: nil
    end)
  end

  defp read_map_field(_other, _key), do: nil

  defp provider_registry_entry(registry, provider_id) when is_map(registry) do
    Enum.find_value(registry, %{}, fn {entry_key, entry_value} ->
      if to_string(entry_key) == provider_id, do: normalize_map(entry_value), else: nil
    end)
  end

  defp provider_registry_entry(_registry, _provider_id), do: %{}

  defp normalize_channel_name(channel_name) do
    channel_name
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_map(map) when is_map(map), do: map
  defp normalize_map(_other), do: %{}

  defp enabled_channel?(channel_cfg) do
    case read_map_field(channel_cfg, "enabled") do
      true -> true
      "true" -> true
      _ -> false
    end
  end

  defp token_required_channel?(channel_name) do
    MapSet.member?(@channels_requiring_token, channel_name)
  end

  defp assisted_ok(id, message, hint, meta) do
    %{id: id, severity: :ok, message: message, hint: hint, meta: meta}
  end

  defp assisted_warn(id, message, hint, meta) do
    %{id: id, severity: :warn, message: message, hint: hint, meta: meta}
  end

  defp normalize_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_string(_), do: nil

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      deep_merge(left_value, right_value)
    end)
  end

  defp deep_merge(_left, right), do: right

  defp yaml_dump(value), do: dump_yaml(value, 0) <> "\n"

  defp dump_yaml(value, indent) when is_map(value) do
    value
    |> Enum.sort_by(fn {k, _} -> to_string(k) end)
    |> Enum.map_join("\n", fn {key, child} ->
      key_prefix = "#{spaces(indent)}#{to_string(key)}:"

      cond do
        is_map(child) and map_size(child) > 0 ->
          key_prefix <> "\n" <> dump_yaml(child, indent + 2)

        is_list(child) ->
          key_prefix <> " " <> dump_list(child)

        true ->
          key_prefix <> " " <> dump_scalar(child)
      end
    end)
  end

  defp dump_list(list) when is_list(list) do
    "[" <> Enum.map_join(list, ", ", &dump_scalar/1) <> "]"
  end

  defp dump_scalar(value) when is_boolean(value), do: to_string(value)
  defp dump_scalar(value) when is_integer(value) or is_float(value), do: to_string(value)

  defp dump_scalar(value) when is_binary(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    ~s("#{escaped}")
  end

  defp dump_scalar(value), do: dump_scalar(to_string(value))

  defp spaces(count), do: String.duplicate(" ", count)
end
