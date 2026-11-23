defmodule Pincer.Core.StartupGuard do
  @moduledoc """
  Pre-flight checks run before the supervision tree starts.

  Each check returns `:ok` or `{:error, atom, message_string}`.

  Checks are run in order and stop at the first error:

  1. `check_config/0` — validates `config.yaml` exists and is parseable.
  2. `check_sandbox/0` — probes the configured sandbox backend; bwrap failures are fatal.
  3. `check_sqlite/0` — verifies the SQLite database path is writable.
  4. `check_migrations/0` — no-op for SQLite; always returns `:ok`.

  The SQLite and migrations checks are skipped when
  `Application.get_env(:pincer, :skip_startup_guard, false)` is `true`
  (used in test environments).
  """

  alias Pincer.Infra.SQLite
  alias Pincer.Ports.Sandbox

  @type check_result :: :ok | {:error, atom(), String.t()}

  @doc """
  Runs all pre-flight checks in sequence.

  Returns `:ok` when all checks pass, or `{:error, check_name, message}` for
  the first check that fails.
  """
  @spec run() :: check_result()
  def run do
    with :ok <- check_config(),
         :ok <- check_sandbox(),
         :ok <- maybe_check_database(),
         :ok <- maybe_check_migrations() do
      :ok
    end
  end

  @doc """
  Validates that `config.yaml` exists and is parseable YAML.

  The path is read from `Application.get_env(:pincer, :config_path, "config.yaml")`.
  """
  @spec check_config() :: check_result()
  def check_config do
    path = Application.get_env(:pincer, :config_path, "config.yaml")

    if File.exists?(path) do
      case YamlElixir.read_from_file(path) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          {:error, :config_invalid, "config.yaml inválido: #{format_reason(reason)}"}
      end
    else
      {:error, :config_missing, "config.yaml não encontrado. Execute: mix pincer.onboard"}
    end
  end

  @doc """
  Probes the configured sandbox backend.

  A backend probe failure is fatal (fail-closed) so a sandbox cannot silently
  degrade to unsandboxed execution at boot.
  """
  @spec check_sandbox() :: check_result()
  def check_sandbox do
    case Sandbox.probe() do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, :sandbox_unavailable, "Sandbox indisponível: #{format_reason(reason)}"}
    end
  end

  @doc """
  Checks for pending database migrations.

  SQLite has no Ecto migration tracking, so this always returns `:ok`.
  """
  @spec check_migrations() :: check_result()
  def check_migrations do
    :ok
  end

  @doc """
  Verifies that the configured SQLite database path and parent directory are writable.
  """
  @spec check_sqlite() :: check_result()
  def check_sqlite do
    path = SQLite.db_path()

    if path == ":memory:" or String.starts_with?(path, "file::memory:") do
      :ok
    else
      dir = Path.dirname(path)
      probe = Path.join(dir, ".pincer_sqlite_write_probe_#{System.unique_integer([:positive])}")

      with :ok <- File.mkdir_p(dir),
           :ok <- File.write(probe, ""),
           :ok <- File.rm(probe) do
        :ok
      else
        {:error, reason} ->
          _ = File.rm(probe)

          {:error, :sqlite_unwritable,
           "SQLite inacessível/sem permissão em #{path}: #{inspect(reason)}"}
      end
    end
  end

  # Private

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp maybe_check_database do
    if skip_guard?(), do: :ok, else: check_sqlite()
  end

  defp maybe_check_migrations do
    if skip_guard?(), do: :ok, else: check_migrations()
  end

  defp skip_guard? do
    Application.get_env(:pincer, :skip_startup_guard, false)
  end
end
