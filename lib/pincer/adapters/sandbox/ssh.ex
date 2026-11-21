defmodule Pincer.Adapters.Sandbox.SSH do
  @moduledoc """
  Remote SSH execution adapter for `Pincer.Ports.Sandbox`.

  Inspired by Nous Research Hermes Agent's `tools/environments/ssh.py`:
  - Fail-fast executable discovery and strict host/user/port validation
  - Guards against SSH option injection (`-oProxyCommand=...`) via leading-dash checks
  - Runs non-interactively with `BatchMode=yes` and optional `ControlMaster` multiplexing
  - POSIX-quotes working directories and validated environment variables
  """

  @behaviour Pincer.Ports.Sandbox

  alias Pincer.Core.WorkspaceGuard
  alias Pincer.Ports.Sandbox

  @default_port 22
  @default_connect_timeout 10
  @default_timeout_ms 30_000
  @host_regex ~r/^[A-Za-z0-9._:-]+$/
  @user_regex ~r/^[A-Za-z0-9._-]+$/

  @impl true
  @spec backend_name() :: atom()
  def backend_name, do: :ssh

  @impl true
  @spec available?() :: boolean()
  def available?, do: find_ssh([]) != nil

  @doc """
  Builds the SSH argument vector after validating target parameters, workspace, and env.
  """
  @spec build_args(String.t(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def build_args(command, opts \\ []) when is_binary(command) and is_list(opts) do
    merged = Keyword.merge(Sandbox.backend_config(:ssh), opts)

    with {:ok, host} <- validate_host(Keyword.get(merged, :host)),
         {:ok, user} <- validate_user(Keyword.get(merged, :user)),
         {:ok, port} <- validate_port(Keyword.get(merged, :port, @default_port)),
         {:ok, env} <- Sandbox.validate_env(Keyword.get(merged, :env)),
         {:ok, remote_workspace} <- validate_remote_workspace(merged),
         :ok <- validate_local_cwd(merged),
         :ok <- validate_remote_command(command, merged) do
      target = if user, do: "#{user}@#{host}", else: host

      strict_host_key = Keyword.get(merged, :strict_host_key_checking, "yes")
      connect_timeout = Keyword.get(merged, :connect_timeout, @default_connect_timeout)
      identity_file = Keyword.get(merged, :identity_file)
      control_path = Keyword.get(merged, :control_path)
      control_persist = Keyword.get(merged, :control_persist, "60s")

      base_args = [
        "-o",
        "BatchMode=yes",
        "-o",
        "StrictHostKeyChecking=#{strict_host_key}",
        "-o",
        "ConnectTimeout=#{connect_timeout}",
        "-p",
        Integer.to_string(port)
      ]

      identity_args =
        if is_binary(identity_file) and identity_file != "" do
          ["-i", identity_file]
        else
          []
        end

      control_args =
        if is_binary(control_path) and control_path != "" do
          [
            "-o",
            "ControlMaster=auto",
            "-o",
            "ControlPath=#{control_path}",
            "-o",
            "ControlPersist=#{control_persist}"
          ]
        else
          []
        end

      remote_command = build_remote_command(command, remote_workspace, env)
      {:ok, base_args ++ identity_args ++ control_args ++ [target, remote_command]}
    end
  end

  @impl true
  @spec run(String.t(), keyword()) :: {:ok, Sandbox.run_result()} | {:error, term()}
  def run(command, opts \\ []) when is_binary(command) and is_list(opts) do
    merged = Keyword.merge(Sandbox.backend_config(:ssh), opts)

    case find_ssh(merged) do
      nil ->
        {:error, :ssh_unavailable}

      exe ->
        with {:ok, args} <- build_args(command, merged) do
          runner = Keyword.get(merged, :runner, &default_runner/3)
          timeout_ms = Keyword.get(merged, :timeout_ms, @default_timeout_ms)
          target = format_target(Keyword.get(merged, :user), Keyword.get(merged, :host))

          case Sandbox.run_with_timeout(
                 fn -> runner.(exe, args, stderr_to_stdout: true) end,
                 timeout_ms
               ) do
            {:ok, {output, exit_code}} when is_integer(exit_code) ->
              {:ok,
               %{
                 output: to_string(output),
                 exit_code: exit_code,
                 backend: :ssh,
                 metadata: %{executable: exe, target: target}
               }}

            {:ok, {:error, reason}} ->
              {:error, reason}

            {:error, _} = error ->
              error
          end
        end
    end
  end

  @impl true
  @spec cleanup(String.t(), keyword()) :: :ok
  def cleanup(scope_id, opts \\ []) when is_binary(scope_id) and is_list(opts) do
    merged = Keyword.merge(Sandbox.backend_config(:ssh), opts)
    control_path = Keyword.get(merged, :control_path)
    host = Keyword.get(merged, :host)

    with exe when is_binary(exe) <- find_ssh(merged),
         true <- is_binary(control_path) and control_path != "",
         {:ok, valid_host} <- validate_host(host) do
      user =
        case validate_user(Keyword.get(merged, :user)) do
          {:ok, u} -> u
          _ -> nil
        end

      target = format_target(user, valid_host)
      runner = Keyword.get(merged, :runner, &default_runner/3)
      runner.(exe, ["-O", "exit", "-S", control_path, target], stderr_to_stdout: true)
      :ok
    else
      _ -> :ok
    end
  end

  # --- Private ---

  defp find_ssh(opts) do
    merged = Keyword.merge(Sandbox.backend_config(:ssh), opts)

    case Keyword.fetch(merged, :executable) do
      {:ok, nil} -> nil
      {:ok, bin} when is_binary(bin) and bin != "" -> bin
      _ -> Keyword.get(merged, :which, &System.find_executable/1).("ssh")
    end
  end

  defp validate_host(host) when is_binary(host) do
    trimmed = String.trim(host)

    cond do
      trimmed == "" -> {:error, :missing_ssh_host}
      String.starts_with?(trimmed, "-") -> {:error, :invalid_ssh_host}
      not Regex.match?(@host_regex, trimmed) -> {:error, :invalid_ssh_host}
      true -> {:ok, trimmed}
    end
  end

  defp validate_host(_), do: {:error, :missing_ssh_host}

  defp validate_user(nil), do: {:ok, nil}

  defp validate_user(user) when is_binary(user) do
    trimmed = String.trim(user)

    cond do
      trimmed == "" -> {:ok, nil}
      String.starts_with?(trimmed, "-") -> {:error, :invalid_ssh_user}
      not Regex.match?(@user_regex, trimmed) -> {:error, :invalid_ssh_user}
      true -> {:ok, trimmed}
    end
  end

  defp validate_user(_), do: {:error, :invalid_ssh_user}

  defp validate_port(port) when is_integer(port) and port >= 1 and port <= 65_535, do: {:ok, port}
  defp validate_port(_), do: {:error, :invalid_ssh_port}

  defp validate_local_cwd(opts) do
    restrict? = Keyword.get(opts, :restrict_to_workspace, false)
    workspace = Keyword.get(opts, :workspace_path)
    cwd = Keyword.get(opts, :cwd)

    if restrict? and is_binary(cwd) and cwd != "" do
      root = workspace || File.cwd!()

      case WorkspaceGuard.confine_path(cwd, root: root, reject_parent_segments: true) do
        {:ok, _} -> :ok
        {:error, _} = err -> err
      end
    else
      :ok
    end
  end

  # The remote working directory is prepended to the remote command, so it must
  # never escape the remote workspace through `..` segments or shell metacharacters.
  defp validate_remote_workspace(opts) do
    case Keyword.get(opts, :remote_workspace) do
      value when is_binary(value) ->
        trimmed = String.trim(value)

        cond do
          trimmed == "" ->
            {:ok, nil}

          String.contains?(trimmed, "\0") ->
            {:error, :invalid_remote_workspace}

          String.contains?(trimmed, "..") ->
            {:error, :invalid_remote_workspace}

          String.match?(trimmed, ~r/[;&|`$<>]|\\(?:\r\n|\n|\r)|[\r\n]/) ->
            {:error, :invalid_remote_workspace}

          true ->
            {:ok, trimmed}
        end

      _ ->
        {:ok, nil}
    end
  end

  defp validate_remote_command(command, opts) do
    if Keyword.get(opts, :restrict_to_workspace, false) do
      case WorkspaceGuard.command_allowed?(command, workspace_root: File.cwd!()) do
        :ok -> :ok
        {:error, _} = err -> err
      end
    else
      :ok
    end
  end

  defp build_remote_command(command, remote_workspace, env) do
    cd_part =
      if is_binary(remote_workspace) and String.trim(remote_workspace) != "" do
        ["cd #{quote_posix(String.trim(remote_workspace))}"]
      else
        []
      end

    env_parts =
      Enum.map(env, fn {k, v} ->
        "export #{k}=#{quote_posix(v)}"
      end)

    case cd_part ++ env_parts do
      [] -> command
      prefixes -> Enum.join(prefixes, " && ") <> " && " <> command
    end
  end

  defp quote_posix(value) do
    escaped = String.replace(to_string(value), "'", "'\\''")
    "'#{escaped}'"
  end

  defp format_target(user, host) when is_binary(user) and user != "", do: "#{user}@#{host}"
  defp format_target(_user, host), do: to_string(host)

  defp default_runner(exe, args, cmd_opts) do
    System.cmd(exe, args, cmd_opts)
  end
end
