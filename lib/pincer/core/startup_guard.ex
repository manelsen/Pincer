defmodule Pincer.Core.StartupGuard do
  @moduledoc """
  Pre-flight checks run before the supervision tree starts.

  Each check returns `:ok` or `{:error, atom, message_string}`.

  Checks are run in order and stop at the first error:

  1. `check_config/0` — validates `config.yaml` exists and is parseable.
  2. `check_database/0` — verifies TCP reachability of the configured DB host/port.
  3. `check_migrations/0` — ensures no pending Ecto migrations remain.

  The DB and migrations checks are skipped when
  `Application.get_env(:pincer, :skip_startup_guard, false)` is `true`
  (used in test environments).
  """

  require Logger

  @type check_result :: :ok | {:error, atom(), String.t()}

  @doc """
  Runs all pre-flight checks in sequence.

  Returns `:ok` when all checks pass, or `{:error, check_name, message}` for
  the first check that fails.
  """
  @spec run() :: check_result()
  def run do
    with :ok <- check_config(),
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
          reason_str = if is_binary(reason), do: reason, else: inspect(reason)
          {:error, :config_invalid, "config.yaml inválido: #{reason_str}"}
      end
    else
      {:error, :config_missing, "config.yaml não encontrado. Execute: mix pincer.onboard"}
    end
  end

  @doc """
  Attempts a raw TCP connection to the configured PostgreSQL host and port.

  Reads host and port from `Application.get_env(:pincer, Pincer.Infra.Repo)`.
  Times out after 2 seconds.
  """
  @spec check_database() :: check_result()
  def check_database do
    repo_config = Application.get_env(:pincer, Pincer.Infra.Repo, [])
    host = Keyword.get(repo_config, :hostname, "localhost")
    port = Keyword.get(repo_config, :port, 5432)

    host_charlist = to_charlist(host)

    case :gen_tcp.connect(host_charlist, port, [], 2_000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :ok

      {:error, _reason} ->
        {:error, :db_unreachable,
         "PostgreSQL inacessível em #{host}:#{port}. Execute: docker compose up -d postgres"}
    end
  end

  @doc """
  Checks for pending Ecto migrations.

  Uses `Ecto.Migrator.with_repo/2` to list all migrations and counts those
  with status `:down`.
  """
  @spec check_migrations() :: check_result()
  def check_migrations do
    result =
      Ecto.Migrator.with_repo(Pincer.Infra.Repo, fn repo ->
        path = Ecto.Migrator.migrations_path(repo)
        Ecto.Migrator.migrations(repo, [path])
      end)

    case result do
      {:ok, migrations, _} ->
        pending = Enum.count(migrations, fn {status, _version, _name} -> status == :down end)

        if pending > 0 do
          {:error, :migrations_pending,
           "#{pending} migrações pendentes. Execute: mix ecto.migrate"}
        else
          :ok
        end

      {:error, reason} ->
        Logger.warning("StartupGuard: could not check migrations: #{inspect(reason)}")
        :ok
    end
  end

  # Private

  defp maybe_check_database do
    if skip_guard?(), do: :ok, else: check_database()
  end

  defp maybe_check_migrations do
    if skip_guard?(), do: :ok, else: check_migrations()
  end

  defp skip_guard? do
    Application.get_env(:pincer, :skip_startup_guard, false)
  end
end
