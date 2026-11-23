defmodule Pincer.Ports.Sandbox do
  @moduledoc """
  Port for isolated command execution backends (Local, Docker, SSH).

  Decouples shell execution policy (`SafeShell` + `WorkspaceGuard`) from the
  execution transport so commands can run in-host via MCP/OS or inside
  ephemeral hardened containers and remote hosts.

  Inspired by Nous Research Hermes Agent's `tools/environments/base.py`
  pluggable environment abstraction, adapted to Elixir behaviours.
  """

  @type run_result :: %{
          output: String.t(),
          exit_code: integer(),
          backend: atom(),
          metadata: map()
        }

  @callback backend_name() :: atom()
  @callback available?() :: boolean()
  @callback probe() :: :ok | {:error, term()}
  @callback run(command :: String.t(), opts :: keyword()) ::
              {:ok, run_result()} | {:error, term()}
  @callback cleanup(scope_id :: String.t()) :: :ok | {:error, term()}

  @optional_callbacks probe: 0

  @env_key_regex ~r/^[A-Za-z_][A-Za-z0-9_]*$/
  @forbidden_env_keys MapSet.new([
                        "LD_PRELOAD",
                        "LD_LIBRARY_PATH",
                        "LD_AUDIT",
                        "LD_ORIGIN_PATH",
                        "DYLD_INSERT_LIBRARIES",
                        "DYLD_LIBRARY_PATH",
                        "DYLD_FRAMEWORK_PATH",
                        "BASH_ENV",
                        "ENV",
                        "IFS"
                      ])

  # --- Dispatcher & Configuration ---

  @doc """
  Returns the currently configured sandbox adapter module.
  """
  @spec adapter() :: module()
  def adapter do
    configured = Application.get_env(:pincer, :sandbox_adapter)

    case resolve_adapter(configured) do
      {:ok, mod} -> mod
      {:error, _} -> default_adapter()
    end
  end

  @doc """
  Resolves a short backend name, atom, or module name into an adapter module.
  """
  @spec resolve_adapter(term()) :: {:ok, module()} | {:error, {:unknown_sandbox_adapter, term()}}
  def resolve_adapter(nil), do: {:ok, default_adapter()}
  def resolve_adapter(:local), do: {:ok, sandbox_module("Local")}
  def resolve_adapter(:docker), do: {:ok, sandbox_module("Docker")}
  def resolve_adapter(:ssh), do: {:ok, sandbox_module("SSH")}
  def resolve_adapter("local"), do: {:ok, sandbox_module("Local")}
  def resolve_adapter("docker"), do: {:ok, sandbox_module("Docker")}
  def resolve_adapter("ssh"), do: {:ok, sandbox_module("SSH")}
  def resolve_adapter("Pincer.Adapters.Sandbox.Local"), do: {:ok, sandbox_module("Local")}
  def resolve_adapter("Pincer.Adapters.Sandbox.Docker"), do: {:ok, sandbox_module("Docker")}
  def resolve_adapter("Pincer.Adapters.Sandbox.SSH"), do: {:ok, sandbox_module("SSH")}

  def resolve_adapter(mod) when is_atom(mod) and not is_boolean(mod) do
    if String.starts_with?(Atom.to_string(mod), "Elixir.") do
      {:ok, mod}
    else
      {:error, {:unknown_sandbox_adapter, mod}}
    end
  end

  def resolve_adapter(name) when is_binary(name) do
    normalized = name |> String.trim() |> String.downcase()

    case normalized do
      "local" ->
        {:ok, sandbox_module("Local")}

      "docker" ->
        {:ok, sandbox_module("Docker")}

      "ssh" ->
        {:ok, sandbox_module("SSH")}

      _ ->
        resolve_module_string(String.trim(name))
    end
  end

  def resolve_adapter(other), do: {:error, {:unknown_sandbox_adapter, other}}

  @doc "Returns the backend identifier atom of the active sandbox adapter."
  @spec backend_name() :: atom()
  def backend_name, do: adapter().backend_name()

  @doc "Returns whether the active sandbox backend is currently available."
  @spec available?() :: boolean()
  def available?, do: adapter().available?()

  @doc """
  Runs the active backend's capability probe.

  Adapters that do not export `probe/0` are assumed to be available.
  """
  @spec probe() :: :ok | {:error, term()}
  def probe do
    mod = adapter()

    if Code.ensure_loaded?(mod) and function_exported?(mod, :probe, 0) do
      mod.probe()
    else
      :ok
    end
  end

  @doc """
  Executes a validated command inside the active sandbox adapter.
  """
  @spec run(String.t(), keyword()) :: {:ok, run_result()} | {:error, term()}
  def run(command, opts \\ []) when is_binary(command) and is_list(opts) do
    adapter().run(command, opts)
  end

  @doc """
  Releases any backend resources scoped to `scope_id`.
  """
  @spec cleanup(String.t()) :: :ok | {:error, term()}
  def cleanup(scope_id) when is_binary(scope_id), do: adapter().cleanup(scope_id)

  @doc """
  Returns backend-specific configuration merged from `:pincer, :sandbox`.
  """
  @spec backend_config(atom()) :: keyword()
  def backend_config(backend) when is_atom(backend) do
    cfg = Application.get_env(:pincer, :sandbox, %{}) || %{}

    raw =
      Map.get(cfg, backend) ||
        Map.get(cfg, Atom.to_string(backend)) ||
        %{}

    cond do
      is_list(raw) ->
        raw

      is_map(raw) ->
        Enum.reduce(raw, [], fn
          {k, v}, acc when is_atom(k) -> Keyword.put(acc, k, v)
          {k, v}, acc when is_binary(k) -> safe_kw_put(acc, k, v)
          _, acc -> acc
        end)

      true ->
        []
    end
  end

  @doc """
  Executes `fun` inside a linked worker task enforcing `timeout_ms`.

  Terminates the task brutally on expiry and returns `{:error, :timeout}`.
  """
  @spec run_with_timeout((-> term()), non_neg_integer() | :infinity | nil) ::
          {:ok, term()} | {:error, :timeout}
  def run_with_timeout(fun, timeout_ms \\ 30_000) when is_function(fun, 0) do
    if is_integer(timeout_ms) and timeout_ms > 0 do
      task = Task.async(fun)

      case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> {:ok, result}
        {:exit, reason} -> {:error, {:task_exit, reason}}
        nil -> {:error, :timeout}
      end
    else
      {:ok, fun.()}
    end
  end

  @doc """
  Validates and normalizes environment variables passed into a sandbox execution.

  Rejects loader-hijack / shell-startup variables (`LD_*`, `DYLD_*`, `BASH_ENV`,
  `ENV`, `IFS`), invalid identifier keys, and non-binary entries.
  """
  @spec validate_env(nil | map() | [{String.t(), String.t()}]) ::
          {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def validate_env(nil), do: {:ok, []}

  def validate_env(env) when is_map(env) do
    env
    |> Map.to_list()
    |> validate_env()
  end

  def validate_env(env) when is_list(env) do
    Enum.reduce_while(env, {:ok, []}, fn
      {key, value}, {:ok, acc} when is_binary(key) and is_binary(value) ->
        cond do
          not Regex.match?(@env_key_regex, key) ->
            {:halt, {:error, {:invalid_env_key, key}}}

          forbidden_env_key?(key) ->
            {:halt, {:error, {:forbidden_env, key}}}

          true ->
            {:cont, {:ok, [{key, value} | acc]}}
        end

      _other, _acc ->
        {:halt, {:error, :invalid_env_entry}}
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  def validate_env(_other), do: {:error, :invalid_env_entry}

  defp safe_kw_put(acc, key_str, val) do
    Keyword.put(acc, String.to_existing_atom(key_str), val)
  rescue
    ArgumentError -> acc
  end

  defp forbidden_env_key?(key) do
    upper = String.upcase(key)
    MapSet.member?(@forbidden_env_keys, upper) or String.starts_with?(upper, "DYLD_")
  end

  defp resolve_module_string(trimmed) do
    parts = trimmed |> String.trim_leading("Elixir.") |> String.split(".", trim: true)

    if parts != [] and Enum.all?(parts, &Regex.match?(~r/^[A-Z][A-Za-z0-9_]*$/, &1)) do
      mod = Module.safe_concat(["Elixir" | parts])

      if Code.ensure_loaded?(mod) do
        {:ok, mod}
      else
        {:error, {:unknown_sandbox_adapter, trimmed}}
      end
    else
      {:error, {:unknown_sandbox_adapter, trimmed}}
    end
  rescue
    ArgumentError -> {:error, {:unknown_sandbox_adapter, trimmed}}
  end

  defp default_adapter, do: sandbox_module("Local")

  defp sandbox_module(name) do
    Module.concat(["Pincer", "Adapters", "Sandbox", name])
  end
end
