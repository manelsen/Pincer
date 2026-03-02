defmodule Pincer.Connectors.MCP.SkillsSidecarPolicy do
  @moduledoc """
  Validates minimum hardening requirements for the `skills_sidecar` MCP server.

  This policy is fail-closed: invalid sidecar configs must not be activated.
  """

  @type validation_error ::
          :invalid_config
          | :invalid_command
          | :docker_run_required
          | {:missing_required_flags, [String.t()]}
          | {:dangerous_docker_flags, [String.t()]}
          | :root_user_not_allowed
          | :sandbox_mount_required
          | {:disallowed_mount_targets, [String.t()]}
          | {:invalid_sandbox_mount_sources, [String.t()]}
          | {:invalid_tmp_mount_sources, [String.t()]}
          | {:sensitive_env_keys_blocked, [String.t()]}
          | :image_required
          | :unpinned_image_digest
          | :artifact_checksum_required
          | :invalid_artifact_checksum

  @sensitive_env_keys [
    "TELEGRAM_BOT_TOKEN",
    "DISCORD_BOT_TOKEN",
    "SLACK_BOT_TOKEN",
    "OPENAI_API_KEY",
    "OPENROUTER_API_KEY",
    "ANTHROPIC_API_KEY",
    "GOOGLE_API_KEY",
    "GITHUB_TOKEN",
    "GITHUB_PERSONAL_ACCESS_TOKEN",
    "AWS_ACCESS_KEY_ID",
    "AWS_SECRET_ACCESS_KEY",
    "DATABASE_URL"
  ]
  @sensitive_env_keyset MapSet.new(@sensitive_env_keys)
  @checksum_regex ~r/^sha256:[0-9a-fA-F]{64}$/
  @allowed_mount_targets ["/sandbox", "/tmp"]
  @allowed_mount_target_set MapSet.new(@allowed_mount_targets)
  @docker_options_with_value MapSet.new([
                               "--network",
                               "--cap-drop",
                               "--pids-limit",
                               "--memory",
                               "--cpus",
                               "--user",
                               "--volume",
                               "--tmpfs",
                               "--cap-add",
                               "--device",
                               "--pid",
                               "--ipc",
                               "--security-opt",
                               "--name",
                               "--workdir",
                               "--entrypoint",
                               "--env"
                             ])
  @short_options_with_value MapSet.new(["-v", "-e", "-w"])

  @spec sensitive_env_keys() :: [String.t()]
  def sensitive_env_keys, do: @sensitive_env_keys

  @spec validate(map()) :: :ok | {:error, validation_error()}
  def validate(cfg) when is_map(cfg) do
    with :ok <- validate_command(cfg),
         {:ok, args} <- validate_args(cfg),
         :ok <- validate_subcommand(args),
         :ok <- validate_required_flags(args),
         :ok <- validate_dangerous_flags(args),
         :ok <- validate_non_root_user(args),
         :ok <- validate_sandbox_mount(args),
         :ok <- validate_mount_targets(args),
         :ok <- validate_sandbox_mount_sources(args),
         :ok <- validate_tmp_mount_sources(args),
         :ok <- validate_env(cfg, args),
         :ok <- validate_image_digest(args),
         :ok <- validate_artifact_checksum(cfg) do
      :ok
    end
  end

  def validate(_), do: {:error, :invalid_config}

  defp validate_command(cfg) do
    case read_field(cfg, :command) do
      command when is_binary(command) ->
        if String.downcase(Path.basename(command)) == "docker" do
          :ok
        else
          {:error, :invalid_command}
        end

      _ ->
        {:error, :invalid_command}
    end
  end

  defp validate_args(cfg) do
    case read_field(cfg, :args) do
      args when is_list(args) ->
        {:ok, Enum.map(args, &to_string/1)}

      _ ->
        {:error, :invalid_config}
    end
  end

  defp validate_subcommand(["run" | _]), do: :ok
  defp validate_subcommand(_), do: {:error, :docker_run_required}

  defp validate_required_flags(args) do
    missing =
      [
        {"--read-only", has_flag?(args, "--read-only")},
        {"--network=none", has_flag_value?(args, "--network", &(&1 == "none"))},
        {"--cap-drop=ALL", has_flag_value?(args, "--cap-drop", &(&1 == "all"))},
        {"--pids-limit", has_flag_value?(args, "--pids-limit", &(String.trim(&1) != ""))},
        {"--memory", has_flag_value?(args, "--memory", &(String.trim(&1) != ""))},
        {"--cpus", has_flag_value?(args, "--cpus", &(String.trim(&1) != ""))},
        {"--user", has_flag_value?(args, "--user", &(String.trim(&1) != ""))}
      ]
      |> Enum.reduce([], fn
        {_label, true}, acc -> acc
        {label, false}, acc -> [label | acc]
      end)
      |> Enum.reverse()

    if missing == [] do
      :ok
    else
      {:error, {:missing_required_flags, missing}}
    end
  end

  defp validate_dangerous_flags(args) do
    dangerous_flags =
      [
        {"--privileged", has_ci_flag?(args, "--privileged")},
        {"--cap-add",
         has_ci_flag?(args, "--cap-add") or has_ci_prefixed_flag?(args, "--cap-add=")},
        {"--device", has_ci_flag?(args, "--device") or has_ci_prefixed_flag?(args, "--device=")},
        {"--pid=host", any_ci_flag_value?(args, "--pid", &(&1 == "host"))},
        {"--ipc=host", any_ci_flag_value?(args, "--ipc", &(&1 == "host"))},
        {"--security-opt=*unconfined*",
         any_ci_flag_value?(args, "--security-opt", &String.contains?(&1, "unconfined"))},
        {"--mount", has_ci_flag?(args, "--mount") or has_ci_prefixed_flag?(args, "--mount=")},
        {"--env-file",
         has_ci_flag?(args, "--env-file") or has_ci_prefixed_flag?(args, "--env-file=")}
      ]
      |> Enum.reduce([], fn
        {_flag, false}, acc -> acc
        {flag, true}, acc -> [flag | acc]
      end)
      |> Enum.uniq()
      |> Enum.sort()

    if dangerous_flags == [] do
      :ok
    else
      {:error, {:dangerous_docker_flags, dangerous_flags}}
    end
  end

  defp validate_non_root_user(args) do
    user_value = flag_value(args, "--user")

    if root_user?(user_value) do
      {:error, :root_user_not_allowed}
    else
      :ok
    end
  end

  defp validate_sandbox_mount(args) do
    has_sandbox_mount =
      args
      |> volume_specs()
      |> Enum.any?(fn spec -> Regex.match?(~r/:(\/sandbox)(:|$)/, spec) end)

    if has_sandbox_mount do
      :ok
    else
      {:error, :sandbox_mount_required}
    end
  end

  defp validate_mount_targets(args) do
    disallowed_targets =
      args
      |> volume_specs()
      |> Enum.map(&mount_target/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.reject(&MapSet.member?(@allowed_mount_target_set, &1))
      |> Enum.uniq()
      |> Enum.sort()

    if disallowed_targets == [] do
      :ok
    else
      {:error, {:disallowed_mount_targets, disallowed_targets}}
    end
  end

  defp validate_sandbox_mount_sources(args) do
    invalid_sources =
      args
      |> volume_specs()
      |> Enum.filter(&(mount_target(&1) == "/sandbox"))
      |> Enum.map(&mount_source/1)
      |> Enum.filter(&invalid_sandbox_mount_source?/1)
      |> Enum.map(&normalize_source_for_report/1)
      |> Enum.uniq()
      |> Enum.sort()

    if invalid_sources == [] do
      :ok
    else
      {:error, {:invalid_sandbox_mount_sources, invalid_sources}}
    end
  end

  defp validate_tmp_mount_sources(args) do
    invalid_sources =
      args
      |> volume_specs()
      |> Enum.filter(&(mount_target(&1) == "/tmp"))
      |> Enum.map(&mount_source/1)
      |> Enum.filter(&invalid_tmp_mount_source?/1)
      |> Enum.map(&normalize_source_for_report/1)
      |> Enum.uniq()
      |> Enum.sort()

    if invalid_sources == [] do
      :ok
    else
      {:error, {:invalid_tmp_mount_sources, invalid_sources}}
    end
  end

  defp validate_env(cfg, args) do
    blocked =
      env_keys(cfg, args)
      |> Enum.filter(&MapSet.member?(@sensitive_env_keyset, &1))
      |> Enum.uniq()
      |> Enum.sort()

    if blocked == [] do
      :ok
    else
      {:error, {:sensitive_env_keys_blocked, blocked}}
    end
  end

  defp validate_image_digest(args) do
    case extract_image_arg(args) do
      nil ->
        {:error, :image_required}

      image ->
        case String.split(image, "@sha256:", parts: 2) do
          [repo, digest] when repo != "" ->
            if valid_sha256_digest?(digest) do
              :ok
            else
              {:error, :unpinned_image_digest}
            end

          _ ->
            {:error, :unpinned_image_digest}
        end
    end
  end

  defp validate_artifact_checksum(cfg) do
    checksum =
      read_field(cfg, :artifact_checksum) ||
        read_field(cfg, :skill_artifact_checksum)

    cond do
      is_nil(checksum) ->
        {:error, :artifact_checksum_required}

      is_binary(checksum) and Regex.match?(@checksum_regex, String.trim(checksum)) ->
        :ok

      true ->
        {:error, :invalid_artifact_checksum}
    end
  end

  defp has_flag?(args, flag), do: Enum.any?(args, &(&1 == flag))

  defp has_ci_flag?(args, flag) do
    normalized = String.downcase(flag)

    Enum.any?(args, fn token ->
      token
      |> to_string()
      |> String.trim()
      |> String.downcase() == normalized
    end)
  end

  defp has_ci_prefixed_flag?(args, prefix) do
    normalized_prefix = String.downcase(prefix)

    Enum.any?(args, fn token ->
      token
      |> to_string()
      |> String.trim()
      |> String.downcase()
      |> String.starts_with?(normalized_prefix)
    end)
  end

  defp has_flag_value?(args, flag, validator) when is_function(validator, 1) do
    case flag_value(args, flag) do
      nil -> false
      value -> validator.(String.downcase(String.trim(value)))
    end
  end

  defp flag_value(args, flag) do
    normalized_flag = String.downcase(flag)

    args
    |> Enum.map(&to_string/1)
    |> do_flag_value(normalized_flag)
  end

  defp any_ci_flag_value?(args, flag, validator) when is_function(validator, 1) do
    normalized_flag = String.downcase(flag)

    args
    |> Enum.map(&to_string/1)
    |> do_any_flag_value(normalized_flag, validator)
  end

  defp do_any_flag_value([], _flag, _validator), do: false

  defp do_any_flag_value([current], flag, validator) do
    case split_flag_value(current) do
      {^flag, value} when is_binary(value) and value != "" ->
        validator.(String.downcase(String.trim(value)))

      _ ->
        false
    end
  end

  defp do_any_flag_value([current, next | rest], flag, validator) do
    case split_flag_value(current) do
      {^flag, value} when is_binary(value) and value != "" ->
        validator.(String.downcase(String.trim(value))) or
          do_any_flag_value([next | rest], flag, validator)

      {^flag, _value} ->
        validator.(String.downcase(String.trim(to_string(next)))) or
          do_any_flag_value(rest, flag, validator)

      _ ->
        do_any_flag_value([next | rest], flag, validator)
    end
  end

  defp extract_image_arg(["run" | rest]), do: do_extract_image_arg(rest)
  defp extract_image_arg(_), do: nil

  defp do_extract_image_arg([]), do: nil

  defp do_extract_image_arg([token | rest]) do
    normalized = token |> to_string() |> String.trim()

    cond do
      normalized == "" ->
        do_extract_image_arg(rest)

      requires_option_value?(normalized) ->
        do_extract_image_arg(drop_option_value(rest))

      option_token?(normalized) ->
        do_extract_image_arg(rest)

      true ->
        normalized
    end
  end

  defp option_token?(token), do: String.starts_with?(token, "-")

  defp requires_option_value?(token) do
    normalized = String.downcase(token)

    cond do
      String.starts_with?(normalized, "--") and String.contains?(normalized, "=") ->
        false

      MapSet.member?(@docker_options_with_value, normalized) ->
        true

      String.starts_with?(normalized, "-v") and normalized != "-v" ->
        false

      MapSet.member?(@short_options_with_value, normalized) ->
        true

      true ->
        false
    end
  end

  defp drop_option_value([_value | rest]), do: rest
  defp drop_option_value([]), do: []

  defp valid_sha256_digest?(digest) when is_binary(digest) do
    Regex.match?(~r/\A[0-9a-f]{64}\z/i, String.trim(digest))
  end

  defp do_flag_value(tokens, flag), do: do_flag_value(tokens, flag, nil)

  defp do_flag_value([], _flag, last_value), do: last_value

  defp do_flag_value([current], flag, last_value) do
    case split_flag_value(current) do
      {^flag, value} ->
        value

      _ ->
        last_value
    end
  end

  defp do_flag_value([current, next | rest], flag, last_value) do
    case split_flag_value(current) do
      {^flag, value} when value != nil and value != "" ->
        do_flag_value([next | rest], flag, value)

      {^flag, _value} ->
        do_flag_value(rest, flag, to_string(next))

      _ ->
        do_flag_value([next | rest], flag, last_value)
    end
  end

  defp split_flag_value(token) do
    token = String.downcase(String.trim(token))

    case String.split(token, "=", parts: 2) do
      [flag, value] -> {flag, value}
      [flag] -> {flag, nil}
    end
  end

  defp root_user?(nil), do: false

  defp root_user?(value) when is_binary(value) do
    normalized = String.downcase(String.trim(value))

    normalized == "root" ||
      normalized == "0" ||
      normalized == "0:0" ||
      String.starts_with?(normalized, "0:")
  end

  defp root_user?(_), do: false

  defp volume_specs(args) do
    do_volume_specs(args, [])
    |> Enum.reverse()
  end

  defp do_volume_specs([], acc), do: acc
  defp do_volume_specs(["-v", spec | rest], acc), do: do_volume_specs(rest, [spec | acc])
  defp do_volume_specs(["--volume", spec | rest], acc), do: do_volume_specs(rest, [spec | acc])

  defp do_volume_specs([flag | rest], acc) do
    token = String.trim(to_string(flag))

    cond do
      String.starts_with?(token, "--volume=") ->
        spec = String.replace_prefix(token, "--volume=", "")
        do_volume_specs(rest, [spec | acc])

      String.starts_with?(token, "-v") and token != "-v" ->
        spec = String.replace_prefix(token, "-v", "")
        do_volume_specs(rest, [spec | acc])

      true ->
        do_volume_specs(rest, acc)
    end
  end

  defp mount_target(spec) when is_binary(spec) do
    parts =
      spec
      |> String.split(":")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    parts
    |> Enum.reverse()
    |> Enum.find(&String.starts_with?(&1, "/"))
    |> case do
      nil ->
        case parts do
          [single] -> normalize_mount_target(single)
          [_source, target | _] -> normalize_mount_target(target)
          _ -> nil
        end

      absolute ->
        normalize_mount_target(absolute)
    end
  end

  defp mount_target(_), do: nil

  defp mount_source(spec) when is_binary(spec) do
    spec
    |> String.split(":")
    |> case do
      [_single] ->
        nil

      [source | _rest] ->
        source
        |> String.trim()
        |> normalize_mount_source()
    end
  end

  defp mount_source(_), do: nil

  defp normalize_mount_target(target) when is_binary(target) do
    case String.trim(target) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_mount_source(source) when is_binary(source) do
    case String.trim(source) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp invalid_sandbox_mount_source?(nil), do: true

  defp invalid_sandbox_mount_source?(source) when is_binary(source) do
    normalized = String.trim(source)

    cond do
      normalized == "" ->
        true

      String.starts_with?(normalized, "/") ->
        true

      String.contains?(normalized, "..") ->
        true

      String.starts_with?(normalized, ".") ->
        false

      String.contains?(normalized, "/") ->
        false

      true ->
        true
    end
  end

  defp invalid_sandbox_mount_source?(_), do: true

  defp invalid_tmp_mount_source?(nil), do: true

  defp invalid_tmp_mount_source?(source) when is_binary(source) do
    normalized = String.trim(source)

    cond do
      normalized == "" ->
        true

      String.starts_with?(normalized, "/") ->
        true

      String.starts_with?(normalized, ".") ->
        true

      String.contains?(normalized, "/") ->
        true

      String.contains?(normalized, "..") ->
        true

      true ->
        not valid_named_volume_source?(normalized)
    end
  end

  defp invalid_tmp_mount_source?(_), do: true

  defp valid_named_volume_source?(source) do
    Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9_.-]*\z/, source)
  end

  defp normalize_source_for_report(nil), do: "(anonymous)"

  defp normalize_source_for_report(source) when is_binary(source) do
    source
    |> String.trim()
    |> case do
      "" -> "(anonymous)"
      normalized -> normalized
    end
  end

  defp env_keys(cfg, args) do
    env_keys_from_config(cfg) ++ env_keys_from_args(args)
  end

  defp env_keys_from_config(cfg) do
    case read_field(cfg, :env) do
      nil ->
        []

      env when is_map(env) ->
        env
        |> Map.keys()
        |> Enum.map(&normalize_env_key/1)
        |> Enum.reject(&(&1 == ""))

      env when is_list(env) ->
        Enum.flat_map(env, fn
          {k, _v} ->
            key = normalize_env_key(k)
            if key == "", do: [], else: [key]

          kv when is_binary(kv) ->
            key =
              kv
              |> String.split("=", parts: 2)
              |> hd()
              |> normalize_env_key()

            if key == "", do: [], else: [key]

          _other ->
            []
        end)

      _other ->
        []
    end
  end

  defp env_keys_from_args(args) when is_list(args) do
    args
    |> Enum.map(&to_string/1)
    |> do_env_keys_from_args([])
    |> Enum.reverse()
    |> Enum.reject(&(&1 == ""))
  end

  defp env_keys_from_args(_), do: []

  defp do_env_keys_from_args([], acc), do: acc

  defp do_env_keys_from_args(["--env", value | rest], acc),
    do: do_env_keys_from_args(rest, add_env_key(value, acc))

  defp do_env_keys_from_args(["-e", value | rest], acc),
    do: do_env_keys_from_args(rest, add_env_key(value, acc))

  defp do_env_keys_from_args([token | rest], acc) do
    normalized = token |> to_string() |> String.trim()
    lowered = String.downcase(normalized)

    cond do
      String.starts_with?(lowered, "--env=") ->
        value = String.replace_prefix(normalized, "--env=", "")
        do_env_keys_from_args(rest, add_env_key(value, acc))

      String.starts_with?(lowered, "-e") and normalized != "-e" ->
        value = String.replace_prefix(normalized, "-e", "")
        do_env_keys_from_args(rest, add_env_key(value, acc))

      true ->
        do_env_keys_from_args(rest, acc)
    end
  end

  defp add_env_key(value, acc) do
    key =
      value
      |> to_string()
      |> String.split("=", parts: 2)
      |> hd()
      |> normalize_env_key()

    if key == "" do
      acc
    else
      [key | acc]
    end
  end

  defp normalize_env_key(key) do
    key
    |> to_string()
    |> String.trim()
    |> String.upcase()
  end

  defp read_field(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp read_field(_, _), do: nil
end
