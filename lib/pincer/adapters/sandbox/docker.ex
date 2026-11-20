defmodule Pincer.Adapters.Sandbox.Docker do
  @moduledoc """
  Hardened ephemeral container execution adapter for `Pincer.Ports.Sandbox`.

  Inspired by Nous Research Hermes Agent's `tools/environments/docker.py`:
  - Drops all Linux capabilities (`--cap-drop ALL`)
  - Enforces `--security-opt no-new-privileges` (unless `snap_compat: true`)
  - Bounds PIDs (`--pids-limit`), memory (`--memory`), CPUs (`--cpus`), and writable `/tmp`/`/var/tmp` tmpfs mounts
  - Defaults to network isolation (`--network none`)
  - Auto-detects `PINCER_DOCKER_BINARY`, `docker`, or `podman`
  - Confines workspace mounts and container working directory via `WorkspaceGuard`
  """

  @behaviour Pincer.Ports.Sandbox

  alias Pincer.Core.WorkspaceGuard
  alias Pincer.Ports.Sandbox

  @default_image "alpine:3.20"
  @default_pids_limit 256
  @default_memory "512m"
  @default_cpus "1.0"
  @default_network "none"
  @default_timeout_ms 30_000

  @impl true
  @spec backend_name() :: atom()
  def backend_name, do: :docker

  @impl true
  @spec available?() :: boolean()
  def available?, do: find_runtime([]) != nil

  @doc """
  Finds the configured container CLI (`docker` or `podman`), or returns `nil`.
  """
  @spec find_runtime(keyword()) :: String.t() | nil
  def find_runtime(opts \\ []) do
    merged = Keyword.merge(Sandbox.backend_config(:docker), opts)

    case Keyword.fetch(merged, :executable) do
      {:ok, nil} ->
        nil

      {:ok, explicit} when is_binary(explicit) and explicit != "" ->
        explicit

      _ ->
        env_finder = Keyword.get(merged, :env_finder, &System.get_env/1)
        which = Keyword.get(merged, :which, &System.find_executable/1)

        case env_finder.("PINCER_DOCKER_BINARY") do
          bin when is_binary(bin) and bin != "" -> bin
          _ -> which.("docker") || which.("podman")
        end
    end
  end

  @doc """
  Sanitizes a Docker label value to valid characters (`[A-Za-z0-9_.-]`) capped at 63 chars.
  """
  @spec sanitize_label(term()) :: String.t()
  def sanitize_label(value) do
    value
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9_.-]/, "_")
    |> String.slice(0, 63)
  end

  @doc """
  Builds the full `docker run` argument vector after validating workspace, cwd, image, and env.
  """
  @spec build_args(String.t(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def build_args(command, opts \\ []) when is_binary(command) and is_list(opts) do
    merged = Keyword.merge(Sandbox.backend_config(:docker), opts)

    with {:ok, env} <- Sandbox.validate_env(Keyword.get(merged, :env)),
         {:ok, host_ws, container_cwd} <- resolve_workspace(merged),
         {:ok, image} <- validate_image(Keyword.get(merged, :image, @default_image)) do
      pids_limit = Keyword.get(merged, :pids_limit, @default_pids_limit)
      memory = Keyword.get(merged, :memory, @default_memory)
      cpus = Keyword.get(merged, :cpus, @default_cpus)
      network = Keyword.get(merged, :network, @default_network)
      snap_compat? = Keyword.get(merged, :snap_compat, false)
      scope_id = Keyword.get(merged, :scope_id)

      args =
        [
          "run",
          "--rm",
          "--cap-drop",
          "ALL"
        ] ++
          if(snap_compat?, do: [], else: ["--security-opt", "no-new-privileges"]) ++
          [
            "--pids-limit",
            to_string(pids_limit),
            "--memory",
            to_string(memory),
            "--cpus",
            to_string(cpus),
            "--tmpfs",
            "/tmp:rw,noexec,nosuid,size=256m",
            "--tmpfs",
            "/var/tmp:rw,noexec,nosuid,size=128m",
            "--network",
            to_string(network),
            "--label",
            "pincer-sandbox=1"
          ] ++
          if(is_binary(scope_id) and scope_id != "",
            do: ["--label", "pincer-scope=#{sanitize_label(scope_id)}"],
            else: []
          ) ++
          [
            "-v",
            "#{host_ws}:/workspace:rw",
            "-w",
            container_cwd
          ] ++
          Enum.flat_map(env, fn {k, v} -> ["-e", "#{k}=#{v}"] end) ++
          [image, "sh", "-c", command]

      {:ok, args}
    end
  end

  @impl true
  @spec run(String.t(), keyword()) :: {:ok, Sandbox.run_result()} | {:error, term()}
  def run(command, opts \\ []) when is_binary(command) and is_list(opts) do
    merged = Keyword.merge(Sandbox.backend_config(:docker), opts)

    case find_runtime(merged) do
      nil ->
        {:error, :docker_unavailable}

      exe ->
        with {:ok, args} <- build_args(command, merged) do
          runner = Keyword.get(merged, :runner, &default_runner/3)
          timeout_ms = Keyword.get(merged, :timeout_ms, @default_timeout_ms)
          image = Keyword.get(merged, :image, @default_image)

          case Sandbox.run_with_timeout(
                 fn -> runner.(exe, args, stderr_to_stdout: true) end,
                 timeout_ms
               ) do
            {:ok, {output, exit_code}} when is_integer(exit_code) ->
              {:ok,
               %{
                 output: to_string(output),
                 exit_code: exit_code,
                 backend: :docker,
                 metadata: %{executable: exe, image: image}
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
    merged = Keyword.merge(Sandbox.backend_config(:docker), opts)

    case find_runtime(merged) do
      nil ->
        :ok

      exe ->
        runner = Keyword.get(merged, :runner, &default_runner/3)
        label = sanitize_label(scope_id)

        case runner.(exe, ["ps", "-aq", "--filter", "label=pincer-scope=#{label}"],
               stderr_to_stdout: true
             ) do
          {out, 0} when is_binary(out) ->
            cids = String.split(out, ~r/\s+/, trim: true)

            if cids != [] do
              runner.(exe, ["rm", "-f" | cids], stderr_to_stdout: true)
            end

            :ok

          _ ->
            :ok
        end
    end
  end

  # --- Private ---

  defp resolve_workspace(opts) do
    workspace_raw = Keyword.get(opts, :workspace_path) || File.cwd!()
    host_ws = Path.expand(workspace_raw)

    case Keyword.get(opts, :cwd) do
      nil ->
        {:ok, host_ws, "/workspace"}

      "" ->
        {:ok, host_ws, "/workspace"}

      cwd ->
        with {:ok, confined} <-
               WorkspaceGuard.confine_path(cwd, root: host_ws, reject_parent_segments: true) do
          rel = Path.relative_to(confined, host_ws)
          container_cwd = if rel == "." or rel == "", do: "/workspace", else: "/workspace/#{rel}"
          {:ok, host_ws, container_cwd}
        end
    end
  end

  defp validate_image(image) when is_binary(image) do
    trimmed = String.trim(image)

    if trimmed != "" and not String.starts_with?(trimmed, "-") and
         not String.contains?(trimmed, ["\0", "\n", "\r", " "]) do
      {:ok, trimmed}
    else
      {:error, :invalid_docker_image}
    end
  end

  defp validate_image(_), do: {:error, :invalid_docker_image}

  defp default_runner(exe, args, cmd_opts) do
    System.cmd(exe, args, cmd_opts)
  end
end
