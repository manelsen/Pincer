defmodule Pincer.Adapters.Sandbox.Bwrap do
  @moduledoc """
  Bubblewrap (`bwrap`) argument builder and capability probe.

  This module is a pure transport helper: it does not decide whether a command
  is allowed. `Pincer.Adapters.Sandbox.Local` still runs `WorkspaceGuard` and
  `SafeShell` policy before asking this module for an argv.

  Isolation is provided by `--unshare-all` (user, pid, net, uts, ipc, cgroup),
  an empty root populated only with read-only system paths, `/proc`, `/dev`, and
  a writable tmpfs `/tmp`. The workspace is bound at `/workspace`, and resource
  limits are applied through `prlimit` when available.

  Linux only. Fail-closed: callers must treat an unavailable probe as an error.
  """

  alias Pincer.Adapters.Sandbox.Runtime

  @default_system_paths ["/usr", "/bin", "/lib", "/lib64"]
  @default_limits %{memory_mb: 1_024, cpu_seconds: 120, pids: 4_096, open_files: 1_024}
  @network_binds ["/etc/resolv.conf", "/etc/hosts", "/etc/nsswitch.conf", "/etc/ssl/certs"]
  @probe_cache_key {__MODULE__, :probe_cache}
  @probe_timeout_ms 2_000
  @probe_prefix_size 200

  @type limit_value :: non_neg_integer()

  @doc """
  Probes whether `bwrap` can create the namespaces and mounts it needs.

  Returns `:ok` on a zero exit status. This function does not use the
  `available?/1` cache; use `available?/1` for the cached capability check.
  """
  @spec probe(keyword()) :: :ok | {:error, term()}
  def probe(opts \\ []) when is_list(opts) do
    exe = resolve_executable(opts)
    runner = Keyword.get(opts, :runner, &default_runner/3)

    with :ok <- ensure_executable(exe) do
      args =
        ["--unshare-all", "--die-with-parent", "--clearenv"] ++
          ro_bind_args(system_paths(opts)) ++
          ["--proc", "/proc", "--dev", "/dev", "--", "/bin/true"]

      run_probe(exe, args, runner)
    end
  end

  @doc """
  Returns whether `bwrap` is usable, caching the probe result per executable.
  """
  @spec available?(keyword()) :: boolean()
  def available?(opts \\ []) when is_list(opts) do
    exe = resolve_executable(opts)
    cache = :persistent_term.get(@probe_cache_key, %{})

    case Map.fetch(cache, exe) do
      {:ok, :ok} ->
        true

      {:ok, {:error, _reason}} ->
        false

      :error ->
        result = probe(opts)
        :persistent_term.put(@probe_cache_key, Map.put(cache, exe, result))
        result == :ok
    end
  end

  @doc """
  Clears the cached probe results.
  """
  @spec reset_probe() :: :ok
  def reset_probe do
    :persistent_term.erase(@probe_cache_key)
    :ok
  end

  @doc """
  Builds the executable and argument vector for running `command` under bwrap.

  `:workspace_path` is required and must be an existing directory other than
  `/`. An optional `:cwd` must be the workspace itself or a directory inside it;
  it is mapped to `/workspace` or `/workspace/<relative>`. Environment entries
  are expected to be validated by `Pincer.Adapters.Sandbox.Runtime.validate_env/1`.
  """
  @spec build_command(String.t(), keyword()) ::
          {:ok, {String.t(), [String.t()]}} | {:error, term()}
  def build_command(command, opts) when is_binary(command) and is_list(opts) do
    with {:ok, workspace} <- validate_workspace(Keyword.get(opts, :workspace_path)),
         :ok <- ensure_executable(resolve_executable(opts)),
         {:ok, container_cwd} <- resolve_container_cwd(workspace, Keyword.get(opts, :cwd)),
         {:ok, env} <- normalize_env(Keyword.get(opts, :env)),
         {:ok, network} <- normalize_network(Keyword.get(opts, :network, :none)),
         {:ok, limits} <- normalize_limits(Keyword.get(opts, :limits, @default_limits)) do
      bwrap_exe = resolve_executable(opts)

      args =
        base_args(workspace, container_cwd, env, network, opts) ++
          ["--", "/bin/sh", "-c", command]

      wrap_limits(bwrap_exe, args, limits, opts)
    end
  end

  # --- Argument construction ---

  defp base_args(workspace, container_cwd, env, network, opts) do
    read_only =
      system_paths(opts) ++
        existing_absolutes(Keyword.get(opts, :extra_ro_binds, [])) ++
        network_binds(network)

    tmpfs_args = if Keyword.get(opts, :tmpfs, true), do: ["--tmpfs", "/tmp"], else: []

    ["--unshare-all", "--die-with-parent", "--new-session", "--clearenv"] ++
      ro_bind_args(read_only) ++
      ["--proc", "/proc", "--dev", "/dev", "--tmpfs", "/dev/shm"] ++
      tmpfs_args ++
      ["--bind", workspace, "/workspace", "--chdir", container_cwd] ++
      [
        "--setenv",
        "PATH",
        "/usr/bin:/bin",
        "--setenv",
        "HOME",
        "/workspace",
        "--setenv",
        "TMPDIR",
        "/tmp"
      ] ++
      Enum.flat_map(env, fn {key, value} -> ["--setenv", key, value] end) ++
      if(network == :host, do: ["--share-net"], else: [])
  end

  defp ro_bind_args(paths) do
    Enum.flat_map(paths, fn path -> ["--ro-bind", path, path] end)
  end

  defp network_binds(:host), do: existing_absolutes(@network_binds)
  defp network_binds(:none), do: []

  defp system_paths(opts) do
    opts
    |> Keyword.get(:system_paths, @default_system_paths)
    |> existing_absolutes()
    |> Enum.uniq()
  end

  defp existing_absolutes(paths) when is_list(paths) do
    paths
    |> Enum.filter(&(is_binary(&1) and Path.type(&1) == :absolute and File.exists?(&1)))
    |> Enum.uniq()
  end

  defp existing_absolutes(_other), do: []

  # --- Validation ---

  defp validate_workspace(path) when is_binary(path) and path != "" do
    expanded = Path.expand(path)

    cond do
      expanded == "/" -> {:error, :invalid_workspace}
      not File.dir?(expanded) -> {:error, :workspace_missing}
      true -> {:ok, expanded}
    end
  end

  defp validate_workspace(_path), do: {:error, :missing_workspace}

  defp resolve_container_cwd(_workspace, nil), do: {:ok, "/workspace"}
  defp resolve_container_cwd(_workspace, ""), do: {:ok, "/workspace"}

  defp resolve_container_cwd(workspace, cwd) when is_binary(cwd) do
    expanded = Path.expand(cwd)

    cond do
      expanded == workspace ->
        {:ok, "/workspace"}

      String.starts_with?(expanded, workspace <> "/") ->
        relative = Path.relative_to(expanded, workspace)
        {:ok, "/workspace/" <> relative}

      true ->
        {:error, :cwd_outside_workspace}
    end
  end

  defp resolve_container_cwd(_workspace, _cwd), do: {:error, :invalid_cwd}

  defp normalize_env(nil), do: {:ok, []}
  defp normalize_env(env) when is_list(env), do: {:ok, env}
  defp normalize_env(_env), do: {:error, :invalid_env_entry}

  defp normalize_network(:none), do: {:ok, :none}
  defp normalize_network(:host), do: {:ok, :host}
  defp normalize_network("none"), do: {:ok, :none}
  defp normalize_network("host"), do: {:ok, :host}
  defp normalize_network(other), do: {:error, {:invalid_network, other}}

  defp normalize_limits(:disabled), do: {:ok, :disabled}
  defp normalize_limits("disabled"), do: {:ok, :disabled}

  defp normalize_limits(limits) when is_map(limits) or is_list(limits) do
    configured =
      limits
      |> Enum.reduce(%{}, fn
        {key, value}, acc when key in [:memory_mb, :cpu_seconds, :pids, :open_files] ->
          Map.put(acc, key, value)

        {key, value}, acc when is_binary(key) ->
          case known_limit_key(key) do
            nil -> acc
            atom -> Map.put(acc, atom, value)
          end

        _entry, acc ->
          acc
      end)

    # A provided limits map replaces the defaults: a missing key disables that
    # limit, matching the (0/absent = disabled) contract.
    limits = %{
      memory_mb: Map.get(configured, :memory_mb, 0),
      cpu_seconds: Map.get(configured, :cpu_seconds, 0),
      pids: Map.get(configured, :pids, 0),
      open_files: Map.get(configured, :open_files, 0)
    }

    if Enum.all?(Map.values(limits), &valid_limit?/1) do
      {:ok, limits}
    else
      {:error, :invalid_limits}
    end
  end

  defp normalize_limits(_limits), do: {:error, :invalid_limits}

  defp known_limit_key(key) do
    case key do
      "memory_mb" -> :memory_mb
      "cpu_seconds" -> :cpu_seconds
      "pids" -> :pids
      "open_files" -> :open_files
      _ -> nil
    end
  end

  defp valid_limit?(value), do: is_integer(value) and value >= 0

  defp ensure_executable(exe) when is_binary(exe) and exe != "" do
    if File.exists?(exe), do: :ok, else: {:error, :bwrap_missing}
  end

  defp ensure_executable(_exe), do: {:error, :bwrap_missing}

  # --- Limits ---

  defp wrap_limits(bwrap_exe, args, :disabled, _opts), do: {:ok, {bwrap_exe, args}}

  defp wrap_limits(bwrap_exe, args, limits, opts) do
    flags = limit_flags(limits)

    if flags == [] do
      {:ok, {bwrap_exe, args}}
    else
      prlimit = resolve_prlimit(opts)

      if is_binary(prlimit) and prlimit != "" and File.exists?(prlimit) do
        {:ok, {prlimit, flags ++ ["--", bwrap_exe | args]}}
      else
        {:error, {:prlimit_unavailable, prlimit}}
      end
    end
  end

  @doc """
  Validates that the effective resource limits can be applied.

  Returns `{:error, {:prlimit_unavailable, path}}` when at least one limit is
  active but `prlimit` cannot be found. `Local.probe/0` uses this so a
  misconfigured bwrap transport fails at boot instead of on every command.
  """
  @spec validate_limits(keyword()) :: :ok | {:error, term()}
  def validate_limits(opts \\ []) when is_list(opts) do
    with {:ok, limits} <- normalize_limits(Keyword.get(opts, :limits, @default_limits)) do
      if limits == :disabled or limit_flags(limits) == [] do
        :ok
      else
        prlimit = resolve_prlimit(opts)

        if is_binary(prlimit) and prlimit != "" and File.exists?(prlimit) do
          :ok
        else
          {:error, {:prlimit_unavailable, prlimit}}
        end
      end
    end
  end

  defp limit_flags(limits) do
    [
      address_space_flag(Map.get(limits, :memory_mb, 0)),
      cpu_flag(Map.get(limits, :cpu_seconds, 0)),
      pids_flag(Map.get(limits, :pids, 0)),
      files_flag(Map.get(limits, :open_files, 0))
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp address_space_flag(mb) when is_integer(mb) and mb > 0, do: "--as=#{mb * 1024 * 1024}"
  defp address_space_flag(_mb), do: nil

  defp cpu_flag(seconds) when is_integer(seconds) and seconds > 0, do: "--cpu=#{seconds}"
  defp cpu_flag(_seconds), do: nil

  defp pids_flag(pids) when is_integer(pids) and pids > 0, do: "--nproc=#{pids}"
  defp pids_flag(_pids), do: nil

  defp files_flag(files) when is_integer(files) and files > 0, do: "--nofile=#{files}"
  defp files_flag(_files), do: nil

  # --- Probe execution ---

  defp run_probe(exe, args, runner) do
    probe_fun = fn ->
      try do
        runner.(exe, args, stderr_to_stdout: true)
      rescue
        error in ErlangError ->
          {:error, error.original}
      end
    end

    case Runtime.run_with_timeout(probe_fun, @probe_timeout_ms) do
      {:ok, {_output, 0}} ->
        :ok

      {:ok, {output, code}} when is_integer(code) ->
        {:error, {:probe_failed, code, output_prefix(output)}}

      {:ok, {:error, :enoent}} ->
        {:error, :bwrap_missing}

      {:ok, {:error, reason}} ->
        {:error, {:probe_failed, :error, output_prefix(reason)}}

      {:ok, other} ->
        {:error, {:probe_failed, :unexpected, output_prefix(other)}}

      {:error, reason} ->
        {:error, {:probe_failed, :timeout, output_prefix(reason)}}
    end
  end

  defp output_prefix(output) when is_binary(output) do
    String.slice(output, 0, @probe_prefix_size)
  end

  defp output_prefix(other) do
    other
    |> inspect()
    |> String.slice(0, @probe_prefix_size)
  end

  # --- Executable resolution ---

  defp resolve_executable(opts) do
    case Keyword.fetch(opts, :executable) do
      {:ok, exe} ->
        exe

      :error ->
        case System.get_env("PINCER_BWRAP_BINARY") do
          bin when is_binary(bin) and bin != "" -> bin
          _ -> System.find_executable("bwrap")
        end
    end
  end

  defp resolve_prlimit(opts) do
    case Keyword.fetch(opts, :prlimit_executable) do
      {:ok, exe} ->
        exe

      :error ->
        case System.get_env("PINCER_PRLIMIT_BINARY") do
          bin when is_binary(bin) and bin != "" -> bin
          _ -> System.find_executable("prlimit")
        end
    end
  end

  defp default_runner(exe, args, opts), do: System.cmd(exe, args, opts)
end
