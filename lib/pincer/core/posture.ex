defmodule Pincer.Core.Posture do
  @moduledoc "Shared configuration findings and reports for local posture commands."

  alias Pincer.Core.ConfigProbe
  alias Pincer.Infra.Config
  alias Pincer.Utils.MapHelpers

  @dm_findings %{
    allowlist: {:ok, "DM policy uses allowlist mode"},
    disabled: {:ok, "DM policy is disabled"},
    pairing: {:ok, "DM policy requires pairing"},
    open: {:warn, "DM policy is open (insecure for production)"},
    missing: {:warn, "DM policy missing (defaults to open behavior)"},
    invalid: {:warn, "DM policy mode is invalid (falls back to open behavior)"},
    malformed: {:warn, "DM policy is malformed (direct messages are disabled)"}
  }

  @doc "Loads a config source and reports the result using the resolved path."
  def read_config(root, config_file) do
    path = Path.expand(config_file, root)

    case Config.load_file(path) do
      {:ok, config} ->
        {path, config, ok_check(:config_yaml, "Config file loaded successfully", %{path: path})}

      {:error, :enoent} ->
        {path, %{},
         error_check(:config_yaml, "Config file not found at #{path}", %{
           path: path,
           reason: :enoent
         })}

      {:error, :invalid_root} ->
        {path, %{},
         error_check(:config_yaml, "Config root must be a map/object", %{
           path: path,
           reason: :invalid_root
         })}

      {:error, {:yaml_error, reason}} ->
        {path, %{},
         error_check(:config_yaml, "Config file is invalid YAML", %{
           path: path,
           reason: inspect(reason)
         })}
    end
  end

  @doc "Checks the authentication environment of each applicable enabled channel."
  def channel_token_checks(config, env_fetcher, check_id) do
    for {channel, env, state} <- ConfigProbe.channel_tokens(config, env_fetcher) do
      case state do
        :present ->
          ok_check({check_id, channel}, "Token env #{env} is present", %{
            channel: channel,
            token_env: env
          })

        :missing_value ->
          error_check(
            {check_id, channel},
            "Missing token env #{env} for enabled channel #{channel}",
            %{channel: channel, token_env: env}
          )

        :missing_env_key ->
          error_check({check_id, channel}, "Enabled channel #{channel} requires token_env", %{
            channel: channel
          })
      end
    end
  end

  @doc "Checks the configured DM mode for enabled channels that support it."
  def dm_checks(config) do
    for {channel, cfg} <- ConfigProbe.enabled_dm_channels(config) do
      mode = cfg |> MapHelpers.read_field(:dm_policy) |> ConfigProbe.dm_mode()
      {severity, message} = Map.fetch!(@dm_findings, mode)

      check(severity, {:dm_policy, channel}, message, %{
        channel: channel,
        mode: Atom.to_string(mode)
      })
    end
  end

  @doc "Builds the diagnostic report while preserving each command's recovery wording."
  def report(checks, config_path, kind) do
    prefix = if kind == :doctor, do: "DOC", else: "AUD"
    run_id = "#{prefix}-#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"

    linked_checks =
      Enum.map(checks, fn check ->
        id = format_id(check.id)

        meta =
          Map.merge(check.meta, %{
            run_id: run_id,
            selection: "selected_by:#{id}",
            recovery: recovery(kind, check.severity, id)
          })

        %{check | meta: meta}
      end)

    {counts, status} = summarize(checks)

    %{
      status: status,
      counts: counts,
      checks: linked_checks,
      config_path: config_path,
      run_id: run_id
    }
  end

  @doc "Adds a hint and reduces a blocking finding to a non-blocking onboarding warning."
  def assisted_check(check, hint) do
    check
    |> Map.update!(:severity, fn severity -> if severity == :error, do: :warn, else: severity end)
    |> Map.put(:hint, hint)
  end

  @doc "Summarizes assisted onboarding checks."
  def assisted_report(checks) do
    {_counts, status} = summarize(checks)
    %{status: status, checks: checks}
  end

  @doc "Constructs a successful diagnostic check."
  def ok_check(id, message, meta), do: check(:ok, id, message, meta)

  @doc "Constructs a warning diagnostic check."
  def warn_check(id, message, meta), do: check(:warn, id, message, meta)

  @doc "Constructs an error diagnostic check."
  def error_check(id, message, meta), do: check(:error, id, message, meta)

  defp check(severity, id, message, meta),
    do: %{id: id, severity: severity, message: message, meta: meta}

  defp summarize(checks) do
    counts =
      Enum.reduce(checks, %{ok: 0, warn: 0, error: 0}, fn check, counts ->
        Map.update!(counts, check.severity, &(&1 + 1))
      end)

    status = Enum.find([:error, :warn], :ok, &(Map.fetch!(counts, &1) > 0))
    {counts, status}
  end

  defp recovery(_kind, :ok, _id), do: "none"
  defp recovery(:doctor, :warn, id), do: "review #{id} and harden configuration"
  defp recovery(:doctor, :error, id), do: "fix #{id} before production rollout"
  defp recovery(:audit, :warn, id), do: "review #{id} and apply hardening controls"
  defp recovery(:audit, :error, id), do: "fix #{id} before enabling public surface"

  defp format_id({left, right}), do: "#{left}:#{right}"
  defp format_id(id), do: to_string(id)
end
