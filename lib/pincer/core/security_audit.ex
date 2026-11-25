defmodule Pincer.Core.SecurityAudit do
  @moduledoc """
  Security posture audit for local runtime configuration.

  Focused checks:
  - channel auth/token exposure
  - DM policy hardening
  - gateway bind risk
  - webhook public bind risk
  """

  alias Pincer.Core.LLM.SkillsSidecarPolicy
  alias Pincer.Core.ConfigProbe
  alias Pincer.Core.Posture
  alias Pincer.Utils.MapHelpers

  import Posture, only: [ok_check: 3, warn_check: 3, error_check: 3]

  @type severity :: :ok | :warn | :error

  @type check :: %{
          id: atom() | {atom(), String.t()},
          severity: severity(),
          message: String.t(),
          meta: map()
        }

  @type report :: %{
          status: severity(),
          counts: %{ok: non_neg_integer(), warn: non_neg_integer(), error: non_neg_integer()},
          checks: [check()],
          config_path: String.t(),
          run_id: String.t()
        }

  @default_config_file "config.yaml"
  @risky_binds MapSet.new(["0.0.0.0", "::", "[::]"])
  @dangerous_flag_paths [
    {"gateway.control_ui.allow_insecure_auth", true,
     ["gateway", "control_ui", "allow_insecure_auth"]},
    {"gateway.control_ui.dangerously_disable_device_auth", true,
     ["gateway", "control_ui", "dangerously_disable_device_auth"]},
    {"hooks.gmail.allow_unsafe_external_content", true,
     ["hooks", "gmail", "allow_unsafe_external_content"]},
    {"tools.exec.apply_patch.workspace_only", false,
     ["tools", "exec", "apply_patch", "workspace_only"]}
  ]

  @spec run(keyword()) :: report()
  def run(opts \\ []) do
    root = Keyword.get(opts, :root, File.cwd!())
    config_file = Keyword.get(opts, :config_file, @default_config_file)
    env_fetcher = Keyword.get(opts, :env_fetcher, &System.get_env/1)
    {config_path, config, config_check} = Posture.read_config(root, config_file)

    checks =
      [config_check] ++
        Posture.channel_token_checks(config, env_fetcher, :channel_auth) ++
        Posture.dm_checks(config) ++
        gateway_bind_checks(config) ++
        webhook_bind_checks(config) ++
        dangerous_flag_checks(config) ++
        workspace_restriction_checks(config) ++
        sidecar_isolation_checks(config)

    Posture.report(checks, config_path, :audit)
  end

  defp gateway_bind_checks(config) do
    bind =
      get_in_path(config, ["gateway", "bind"]) ||
        get_in_path(config, ["server", "bind"]) ||
        Map.get(config, "bind")

    if MapHelpers.present?(bind) do
      normalized =
        bind
        |> to_string()
        |> String.trim()
        |> String.downcase()

      if MapSet.member?(@risky_binds, normalized) do
        [
          warn_check(
            :gateway_bind,
            "Gateway bind #{bind} exposes network surface to all interfaces",
            %{bind: bind}
          )
        ]
      else
        [ok_check(:gateway_bind, "Gateway bind is restricted", %{bind: bind})]
      end
    else
      []
    end
  end

  defp webhook_bind_checks(config) do
    case Enum.find(channels(config), fn {name, _cfg} -> name == "webhook" end) do
      nil ->
        []

      {_name, cfg} ->
        bind = MapHelpers.read_field(cfg, :bind)

        cond do
          not enabled?(cfg) ->
            [
              ok_check(
                :webhook_public_bind,
                "Webhook channel is disabled",
                %{bind: bind, status: :disabled}
              )
            ]

          risky_bind?(bind) ->
            [
              warn_check(
                :webhook_public_bind,
                "Webhook bind #{bind} exposes the HTTP ingress to all interfaces",
                %{bind: bind}
              )
            ]

          true ->
            [ok_check(:webhook_public_bind, "Webhook bind is restricted", %{bind: bind})]
        end
    end
  end

  defp risky_bind?(bind) when is_binary(bind) do
    normalized = bind |> String.trim() |> String.downcase()
    MapSet.member?(@risky_binds, normalized)
  end

  defp risky_bind?(_bind), do: false

  defp dangerous_flag_checks(config) do
    direct_flags =
      Enum.reduce(@dangerous_flag_paths, [], fn {name, expected_value, path}, acc ->
        if get_in_path(config, path) == expected_value do
          [name | acc]
        else
          acc
        end
      end)

    mapping_flags =
      config
      |> get_in_path(["hooks", "mappings"])
      |> case do
        mappings when is_list(mappings) ->
          mappings
          |> Enum.with_index()
          |> Enum.flat_map(fn {mapping, index} ->
            if get_in_path(mapping, ["allow_unsafe_external_content"]) == true do
              ["hooks.mappings[#{index}].allow_unsafe_external_content"]
            else
              []
            end
          end)

        _ ->
          []
      end

    (direct_flags ++ mapping_flags)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn path ->
      warn_check(
        {:dangerous_flag, path},
        "Dangerous config flag enabled: #{path}",
        %{path: path}
      )
    end)
  end

  defp workspace_restriction_checks(config) do
    value = get_in_path(config, ["tools", "restrict_to_workspace"])

    case value do
      false ->
        [
          error_check(
            :tools_restrict_workspace,
            "Workspace restriction disabled for tools runtime",
            %{path: "tools.restrict_to_workspace", value: false}
          )
        ]

      true ->
        [
          ok_check(
            :tools_restrict_workspace,
            "Workspace restriction enabled for tools runtime",
            %{path: "tools.restrict_to_workspace", value: true}
          )
        ]

      nil ->
        [
          ok_check(
            :tools_restrict_workspace,
            "Workspace restriction not explicitly set (secure default assumed)",
            %{path: "tools.restrict_to_workspace", value: :default_true}
          )
        ]

      _other ->
        [
          warn_check(
            :tools_restrict_workspace,
            "Workspace restriction has invalid value (expected boolean)",
            %{path: "tools.restrict_to_workspace", value: inspect(value)}
          )
        ]
    end
  end

  defp sidecar_isolation_checks(config) do
    sidecar_cfg = get_in_path(config, ["mcp", "servers", "skills_sidecar"])

    case sidecar_cfg do
      nil ->
        [
          ok_check(
            :mcp_skills_sidecar_isolation,
            "MCP skills_sidecar not configured (sidecar disabled)",
            %{server: "skills_sidecar", status: :absent}
          )
        ]

      cfg when is_map(cfg) ->
        case SkillsSidecarPolicy.validate(cfg) do
          :ok ->
            [
              ok_check(
                :mcp_skills_sidecar_isolation,
                "MCP skills_sidecar uses hardened isolation profile",
                %{server: "skills_sidecar", status: :hardened}
              )
            ]

          {:error, reason} ->
            [
              error_check(
                :mcp_skills_sidecar_isolation,
                "MCP skills_sidecar isolation is invalid",
                %{server: "skills_sidecar", reason: inspect(reason)}
              )
            ]
        end

      _other ->
        [
          error_check(
            :mcp_skills_sidecar_isolation,
            "MCP skills_sidecar config must be a map/object",
            %{server: "skills_sidecar", reason: :invalid_config}
          )
        ]
    end
  end

  defp channels(config), do: ConfigProbe.channels(config)

  defp enabled?(cfg), do: ConfigProbe.enabled?(cfg)

  defp get_in_path(map, []), do: map

  defp get_in_path(map, [key | rest]) when is_map(map) do
    case Map.get(map, key) do
      nil -> nil
      value -> get_in_path(value, rest)
    end
  end

  defp get_in_path(_other, _path), do: nil
end
