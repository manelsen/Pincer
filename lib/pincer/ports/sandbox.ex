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

  @sandbox_short_names %{
    "local" => :local,
    "docker" => :docker,
    "ssh" => :ssh
  }

  # --- Dispatcher & Configuration ---

  @doc """
  Returns the currently configured sandbox adapter module.
  """
  @spec adapter() :: module()
  def adapter do
    case Application.fetch_env(:pincer, :sandbox_adapter) do
      {:ok, nil} ->
        raise ArgumentError,
              "missing :sandbox_adapter configuration for :pincer (got nil)"

      {:ok, configured} ->
        case resolve_adapter(configured) do
          {:ok, mod} ->
            mod

          {:error, reason} ->
            raise ArgumentError,
                  "invalid :sandbox_adapter configuration for :pincer: #{inspect(reason)}"
        end

      :error ->
        raise ArgumentError,
              "missing :sandbox_adapter configuration for :pincer (configure config :pincer, :sandbox_adapter, ...)"
    end
  end

  @doc """
  Resolves a short backend name, atom, or module name into an adapter module.
  """
  @spec resolve_adapter(term()) :: {:ok, module()} | {:error, {:unknown_sandbox_adapter, term()}}
  def resolve_adapter(nil), do: {:error, {:unknown_sandbox_adapter, nil}}

  def resolve_adapter(key) when key in [:local, :docker, :ssh] do
    resolve_short_adapter(key, key)
  end

  def resolve_adapter(mod) when is_atom(mod) and not is_boolean(mod) do
    if String.starts_with?(Atom.to_string(mod), "Elixir.") do
      {:ok, mod}
    else
      {:error, {:unknown_sandbox_adapter, mod}}
    end
  end

  def resolve_adapter(name) when is_binary(name) do
    trimmed = String.trim(name)
    normalized = String.downcase(trimmed)

    case Map.fetch(@sandbox_short_names, normalized) do
      {:ok, key} ->
        resolve_short_adapter(key, name)

      :error ->
        resolve_module_string(trimmed)
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

  defp resolve_short_adapter(key, original) do
    adapters = Application.get_env(:pincer, :sandbox_adapters, %{})
    str_key = Atom.to_string(key)

    mod =
      cond do
        is_map(adapters) -> Map.get(adapters, key) || Map.get(adapters, str_key)
        Keyword.keyword?(adapters) -> Keyword.get(adapters, key)
        true -> nil
      end

    if is_atom(mod) and not is_nil(mod) and not is_boolean(mod) do
      {:ok, mod}
    else
      {:error, {:unknown_sandbox_adapter, original}}
    end
  end
end
