defmodule Pincer.Adapters.Sandbox.Local do
  @moduledoc """
  Local sandbox execution adapter for `Pincer.Ports.Sandbox`.

  Supports two transports:
  - `:tool_registry` (default) — delegates `"run_command"` through `Pincer.Ports.ToolRegistry`,
    preserving MCP server execution and existing `SafeShell` integration behaviour.
  - `:os` - executes via `sh -c` with explicit timeout enforcement, `WorkspaceGuard`
    directory confinement and the same tokenized command allowlist enforced elsewhere.
  """

  @behaviour Pincer.Ports.Sandbox

  alias Pincer.Core.WorkspaceGuard
  alias Pincer.Ports.Sandbox

  @default_timeout_ms 30_000

  @impl true
  @spec backend_name() :: atom()
  def backend_name, do: :local

  @impl true
  @spec available?() :: boolean()
  def available? do
    case Keyword.get(Sandbox.backend_config(:local), :transport, :tool_registry) do
      :os -> System.find_executable("sh") != nil
      "os" -> System.find_executable("sh") != nil
      _ -> true
    end
  end

  @impl true
  @spec run(String.t(), keyword()) :: {:ok, Sandbox.run_result()} | {:error, term()}
  def run(command, opts \\ []) when is_binary(command) and is_list(opts) do
    merged_opts = Keyword.merge(Sandbox.backend_config(:local), opts)

    with {:ok, env} <- Sandbox.validate_env(Keyword.get(merged_opts, :env)),
         {:ok, cwd} <- resolve_cwd(merged_opts) do
      case normalize_transport(Keyword.get(merged_opts, :transport, :tool_registry)) do
        :os -> run_os(command, cwd, env, merged_opts)
        :tool_registry -> run_tool_registry(command, cwd, merged_opts)
      end
    end
  end

  @impl true
  @spec cleanup(String.t()) :: :ok
  def cleanup(_scope_id), do: :ok

  # --- Private ---

  defp normalize_transport(:os), do: :os
  defp normalize_transport("os"), do: :os
  defp normalize_transport(_), do: :tool_registry

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

  # The `:os` transport executes an arbitrary shell string, so it must obey the
  # same tokenized allowlist as every other execution path.
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
end
