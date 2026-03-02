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
          config_path: String.t()
        }

  @default_config_file "config.yaml"
  @channels_requiring_token MapSet.new(["telegram", "discord", "slack"])
  @dm_capable_channels MapSet.new(["telegram", "discord"])

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
    config_path = resolve_config_path(root, config_file)

    {config, checks} =
      case load_config(config_path) do
        {:ok, loaded_config, config_check} ->
          {loaded_config, [config_check]}

        {:error, config_check} ->
          {%{}, [config_check]}
      end

    checks =
      checks ++
        channel_token_checks(config, env_fetcher) ++
        dm_policy_checks(config)

    counts = counts(checks)
    status = status_from_counts(counts)

    %{
      status: status,
      counts: counts,
      checks: checks,
      config_path: config_path
    }
  end

  defp resolve_config_path(root, config_file) do
    if Path.type(config_file) == :absolute do
      config_file
    else
      Path.expand(config_file, root)
    end
  end

  defp load_config(path) do
    cond do
      not File.exists?(path) ->
        {:error,
         error_check(
           :config_yaml,
           "Config file not found at #{path}",
           %{path: path, reason: :enoent}
         )}

      true ->
        case YamlElixir.read_from_file(path) do
          {:ok, config} when is_map(config) ->
            {:ok, config,
             ok_check(:config_yaml, "Config file loaded successfully", %{path: path})}

          {:ok, _config} ->
            {:error,
             error_check(
               :config_yaml,
               "Config root must be a map/object",
               %{path: path, reason: :invalid_root}
             )}

          {:error, reason} ->
            {:error,
             error_check(
               :config_yaml,
               "Config file is invalid YAML",
               %{path: path, reason: inspect(reason)}
             )}
        end
    end
  end

  defp channel_token_checks(config, env_fetcher) do
    channels(config)
    |> Enum.filter(fn {_, channel_cfg} -> enabled?(channel_cfg) end)
    |> Enum.flat_map(fn {channel_name, channel_cfg} ->
      token_env = read_field(channel_cfg, :token_env)

      cond do
        present?(token_env) ->
          env_value = env_fetcher.(token_env)

          if present?(env_value) do
            [
              ok_check(
                {:channel_token, channel_name},
                "Token env #{token_env} is present",
                %{channel: channel_name, token_env: token_env}
              )
            ]
          else
            [
              error_check(
                {:channel_token, channel_name},
                "Missing token env #{token_env} for enabled channel #{channel_name}",
                %{channel: channel_name, token_env: token_env}
              )
            ]
          end

        token_required_channel?(channel_name) ->
          [
            error_check(
              {:channel_token, channel_name},
              "Enabled channel #{channel_name} requires token_env",
              %{channel: channel_name}
            )
          ]

        true ->
          []
      end
    end)
  end

  defp dm_policy_checks(config) do
    channels(config)
    |> Enum.filter(fn {name, channel_cfg} ->
      enabled?(channel_cfg) and dm_capable_channel?(name)
    end)
    |> Enum.map(fn {channel_name, channel_cfg} ->
      dm_policy = read_field(channel_cfg, :dm_policy)
      mode = normalize_dm_mode(dm_policy)

      case mode do
        :allowlist ->
          ok_check(
            {:dm_policy, channel_name},
            "DM policy uses allowlist mode",
            %{channel: channel_name, mode: "allowlist"}
          )

        :disabled ->
          ok_check(
            {:dm_policy, channel_name},
            "DM policy is disabled",
            %{channel: channel_name, mode: "disabled"}
          )

        :pairing ->
          ok_check(
            {:dm_policy, channel_name},
            "DM policy requires pairing",
            %{channel: channel_name, mode: "pairing"}
          )

        :open ->
          warn_check(
            {:dm_policy, channel_name},
            "DM policy is open (insecure for production)",
            %{channel: channel_name, mode: "open"}
          )

        :missing ->
          warn_check(
            {:dm_policy, channel_name},
            "DM policy missing (defaults to open behavior)",
            %{channel: channel_name, mode: "missing"}
          )

        :invalid ->
          warn_check(
            {:dm_policy, channel_name},
            "DM policy mode is invalid (falls back to open behavior)",
            %{channel: channel_name, mode: "invalid"}
          )
      end
    end)
  end

  defp channels(config) when is_map(config) do
    case read_field(config, :channels) do
      map when is_map(map) ->
        map
        |> Enum.map(fn {name, cfg} ->
          {normalize_channel_name(name), normalize_config_map(cfg)}
        end)

      _ ->
        []
    end
  end

  defp token_required_channel?(channel_name) do
    MapSet.member?(@channels_requiring_token, channel_name)
  end

  defp dm_capable_channel?(channel_name) do
    MapSet.member?(@dm_capable_channels, channel_name)
  end

  defp enabled?(cfg) when is_map(cfg) do
    case read_field(cfg, :enabled) do
      true -> true
      "true" -> true
      _ -> false
    end
  end

  defp enabled?(_), do: false

  defp normalize_dm_mode(nil), do: :missing

  defp normalize_dm_mode(dm_policy) when is_map(dm_policy) do
    dm_policy
    |> read_field(:mode)
    |> normalize_dm_mode_value()
  end

  defp normalize_dm_mode(_), do: :invalid

  defp normalize_dm_mode_value(nil), do: :missing
  defp normalize_dm_mode_value(""), do: :missing

  defp normalize_dm_mode_value(mode) do
    case mode |> to_string() |> String.trim() |> String.downcase() do
      "open" -> :open
      "allowlist" -> :allowlist
      "disabled" -> :disabled
      "pairing" -> :pairing
      _ -> :invalid
    end
  end

  defp normalize_channel_name(name) do
    name
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_config_map(map) when is_map(map), do: map
  defp normalize_config_map(_), do: %{}

  defp counts(checks) do
    %{ok: 0, warn: 0, error: 0}
    |> put_count(:ok, checks)
    |> put_count(:warn, checks)
    |> put_count(:error, checks)
  end

  defp put_count(acc, severity, checks) do
    Map.put(acc, severity, Enum.count(checks, &(&1.severity == severity)))
  end

  defp status_from_counts(%{error: errors}) when errors > 0, do: :error
  defp status_from_counts(%{warn: warnings}) when warnings > 0, do: :warn
  defp status_from_counts(_), do: :ok

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)

  defp read_field(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp read_field(_, _), do: nil

  defp ok_check(id, message, meta) do
    %{id: id, severity: :ok, message: message, meta: meta}
  end

  defp warn_check(id, message, meta) do
    %{id: id, severity: :warn, message: message, meta: meta}
  end

  defp error_check(id, message, meta) do
    %{id: id, severity: :error, message: message, meta: meta}
  end
end
