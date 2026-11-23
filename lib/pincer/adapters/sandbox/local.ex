defmodule Pincer.Adapters.Sandbox.Local do
  @moduledoc """
  Local sandbox execution adapter for `Pincer.Ports.Sandbox`.

  Supports three transports:
  - `:tool_registry` (default) — delegates `"run_command"` through `Pincer.Ports.ToolRegistry`,
    preserving MCP server execution and existing `SafeShell` integration behaviour.
  - `:os` - executes via `sh -c` with explicit timeout enforcement, `WorkspaceGuard`
    directory confinement and the same tokenized command allowlist enforced elsewhere.
  - `:bwrap` - executes the same validated command inside a bubblewrap namespace.
    This is Linux-only and fail-closed: if the probe fails, the command is not run.

  The bwrap transport is opt-in with `transport: "bwrap"` or `bwrap: true`. Its
  nested configuration accepts `network`, `limits`, `executable`,
  `prlimit_executable`, and `extra_ro_binds` keys.
  """

  @behaviour Pincer.Ports.Sandbox

  alias Pincer.Adapters.Sandbox.Bwrap
  alias Pincer.Core.WorkspaceGuard
  alias Pincer.Ports.Sandbox

  @default_timeout_ms 30_000

  @bwrap_keys %{
    "network" => :network,
    "limits" => :limits,
    "executable" => :executable,
    "prlimit_executable" => :prlimit_executable,
    "extra_ro_binds" => :extra_ro_binds,
    "system_paths" => :system_paths,
    "tmpfs" => :tmpfs
  }

  @impl true
  @spec backend_name() :: atom()
  def backend_name, do: :local

  @impl true
  @spec available?() :: boolean()
  def available? do
    config = Sandbox.backend_config(:local)

    case transport_mode(config) do
      :bwrap ->
        opts = bwrap_probe_opts(config)
        Bwrap.available?(opts) and match?(:ok, Bwrap.validate_limits(opts))

      :os ->
        System.find_executable("sh") != nil

      :tool_registry ->
        true
    end
  end

  @impl true
  @spec probe() :: :ok | {:error, term()}
  def probe do
    config = Sandbox.backend_config(:local)

    case transport_mode(config) do
      :bwrap ->
        opts = bwrap_probe_opts(config)

        with :ok <- Bwrap.probe(opts),
             :ok <- Bwrap.validate_limits(opts) do
          :ok
        end

      _ ->
        :ok
    end
  end

  @impl true
  @spec run(String.t(), keyword()) :: {:ok, Sandbox.run_result()} | {:error, term()}
  def run(command, opts \\ []) when is_binary(command) and is_list(opts) do
    merged_opts = Keyword.merge(Sandbox.backend_config(:local), opts)

    with {:ok, env} <- Sandbox.validate_env(Keyword.get(merged_opts, :env)),
         {:ok, cwd} <- resolve_cwd(merged_opts) do
      case transport_mode(merged_opts) do
        :bwrap -> run_bwrap(command, cwd, env, merged_opts)
        :os -> run_os(command, cwd, env, merged_opts)
        :tool_registry -> run_tool_registry(command, cwd, merged_opts)
      end
    end
  end

  @impl true
  @spec cleanup(String.t()) :: :ok
  def cleanup(_scope_id), do: :ok

  # --- Private ---

  defp normalize_transport(:bwrap), do: :bwrap
  defp normalize_transport("bwrap"), do: :bwrap
  defp normalize_transport(:os), do: :os
  defp normalize_transport("os"), do: :os
  defp normalize_transport(_), do: :tool_registry

  # An explicit transport wins over `bwrap: true`; when transport is absent (or
  # the default tool registry), a nested bwrap config opts into bubblewrap.
  defp transport_mode(opts) do
    case normalize_transport(Keyword.get(opts, :transport, :tool_registry)) do
      :bwrap -> :bwrap
      :os -> :os
      :tool_registry -> if bwrap_configured?(opts), do: :bwrap, else: :tool_registry
    end
  end

  defp bwrap_configured?(opts) do
    case Keyword.get(opts, :bwrap) do
      nil -> false
      false -> false
      _config -> true
    end
  end

  defp resolve_cwd(opts) do
    restrict? = Keyword.get(opts, :restrict_to_workspace, true)
    workspace_path = Keyword.get(opts, :workspace_path)
    cwd = Keyword.get(opts, :cwd)

    cond do
      not restrict? ->
        {:ok, if(is_binary(cwd) and cwd != "", do: Path.expand(cwd), else: nil)}

      is_binary(workspace_path) and workspace_path != "" and is_binary(cwd) and cwd != "" ->
        WorkspaceGuard.confine_path(cwd, root: workspace_path, reject_parent_segments: true)

      is_binary(workspace_path) and workspace_path != "" ->
        {:ok, Path.expand(workspace_path)}

      is_binary(cwd) and cwd != "" ->
        WorkspaceGuard.confine_path(cwd, root: File.cwd!(), reject_parent_segments: true)

      true ->
        {:ok, nil}
    end
  end

  defp run_bwrap(command, cwd, env, opts) do
    workspace = Keyword.get(opts, :workspace_path) || cwd || File.cwd!()

    with :ok <-
           ensure_os_command_allowed(command, cwd, Keyword.put(opts, :workspace_path, workspace)),
         :ok <- ensure_bwrap_available(opts),
         bwrap_opts = bwrap_options(opts, workspace, cwd, env),
         {:ok, {exe, args}} <- Bwrap.build_command(command, bwrap_opts) do
      runner = Keyword.get(opts, :bwrap_runner, &default_bwrap_runner/3)
      timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

      case Sandbox.run_with_timeout(
             fn -> runner.(exe, args, stderr_to_stdout: true) end,
             timeout_ms
           ) do
        {:ok, {output, exit_code}} when is_integer(exit_code) ->
          {:ok,
           %{
             output: to_string(output),
             exit_code: exit_code,
             backend: :local,
             metadata: %{transport: :bwrap, network: bwrap_network(bwrap_opts)}
           }}

        {:ok, {:error, reason}} ->
          {:error, reason}

        {:error, _} = error ->
          error
      end
    end
  end

  defp bwrap_options(opts, workspace, cwd, env) do
    opts
    |> Keyword.get(:bwrap)
    |> normalize_bwrap_config()
    |> Keyword.put(:workspace_path, workspace)
    |> then(fn acc ->
      if is_binary(cwd) and cwd != "", do: Keyword.put(acc, :cwd, cwd), else: acc
    end)
    |> Keyword.put(:env, env)
  end

  defp normalize_bwrap_config(config) when is_map(config) do
    Enum.reduce(config, [], fn {key, value}, acc ->
      case known_bwrap_key(key) do
        nil -> acc
        atom -> Keyword.put(acc, atom, value)
      end
    end)
  end

  defp normalize_bwrap_config(config) when is_list(config) do
    Enum.reduce(config, [], fn
      {key, value}, acc ->
        case known_bwrap_key(key) do
          nil -> acc
          atom -> Keyword.put(acc, atom, value)
        end

      _entry, acc ->
        acc
    end)
  end

  defp normalize_bwrap_config(_config), do: []

  defp bwrap_probe_opts(config) do
    config
    |> Keyword.get(:bwrap)
    |> normalize_bwrap_config()
  end

  defp known_bwrap_key(key) when is_atom(key) do
    case Map.fetch(@bwrap_keys, Atom.to_string(key)) do
      {:ok, atom} -> atom
      :error -> nil
    end
  end

  defp known_bwrap_key(key) when is_binary(key), do: Map.get(@bwrap_keys, key)
  defp known_bwrap_key(_key), do: nil

  defp ensure_bwrap_available(opts) do
    result =
      cond do
        Keyword.has_key?(opts, :bwrap_probe) ->
          invoke_probe(Keyword.get(opts, :bwrap_probe))

        Keyword.has_key?(opts, :bwrap_available) ->
          invoke_probe(Keyword.get(opts, :bwrap_available))

        true ->
          config = normalize_bwrap_config(Keyword.get(opts, :bwrap))
          Bwrap.available?(config) and match?(:ok, Bwrap.validate_limits(config))
      end

    case normalize_availability(result) do
      :ok -> :ok
      {:error, reason} -> {:error, {:bwrap_unavailable, reason}}
    end
  end

  defp invoke_probe(fun) when is_function(fun, 0), do: fun.()
  defp invoke_probe(value), do: value

  defp normalize_availability(:ok), do: :ok
  defp normalize_availability(true), do: :ok
  defp normalize_availability(false), do: {:error, :unavailable}
  defp normalize_availability(nil), do: {:error, :unavailable}
  defp normalize_availability({:error, _reason} = error), do: error
  defp normalize_availability(other), do: {:error, other}

  defp bwrap_network(opts) do
    case Keyword.get(opts, :network, :none) do
      :host -> :host
      "host" -> :host
      _other -> :none
    end
  end

  defp run_tool_registry(command, cwd, opts) do
    payload =
      if is_binary(cwd) and cwd != "" do
        %{"command" => command, "cwd" => cwd}
      else
        %{"command" => command}
      end

    context = Keyword.get(opts, :context, %{})

    case Pincer.Ports.ToolRegistry.execute_tool("run_command", payload, context) do
      {:ok, result} ->
        {:ok,
         %{
           output: to_string(result),
           exit_code: 0,
           backend: :local,
           metadata: %{transport: :tool_registry}
         }}

      {:error, reason} ->
        {:error, "Shell execution failed: #{inspect(reason)}"}
    end
  end

  defp run_os(command, cwd, env, opts) do
    runner = Keyword.get(opts, :runner, &default_os_runner/2)
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    with :ok <- ensure_os_command_allowed(command, cwd, opts) do
      cmd_opts =
        [stderr_to_stdout: true]
        |> then(fn acc -> if cwd, do: Keyword.put(acc, :cd, cwd), else: acc end)
        |> then(fn acc -> if env != [], do: Keyword.put(acc, :env, env), else: acc end)

      case Sandbox.run_with_timeout(fn -> runner.(command, cmd_opts) end, timeout_ms) do
        {:ok, {output, exit_code}} when is_integer(exit_code) ->
          {:ok,
           %{
             output: to_string(output),
             exit_code: exit_code,
             backend: :local,
             metadata: %{transport: :os}
           }}

        {:ok, {:error, reason}} ->
          {:error, reason}

        {:error, _} = error ->
          error
      end
    end
  end

  # The `:os` and `:bwrap` transports execute an arbitrary shell string, so they
  # must obey the same tokenized allowlist as every other execution path.
  defp ensure_os_command_allowed(command, cwd, opts) do
    workspace_root =
      case cwd || Keyword.get(opts, :workspace_path) do
        path when is_binary(path) and path != "" -> Path.expand(path)
        _ -> File.cwd!()
      end

    case WorkspaceGuard.command_allowed?(command, workspace_root: workspace_root) do
      :ok -> :ok
      {:error, reason} -> {:error, {:command_not_allowed, reason}}
    end
  end

  defp default_os_runner(command, cmd_opts) do
    System.cmd("sh", ["-c", command], cmd_opts)
  end

  defp default_bwrap_runner(exe, args, cmd_opts) do
    System.cmd(exe, args, cmd_opts)
  end
end
