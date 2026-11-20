defmodule Pincer.Core.Onboard.Preflight do
  @moduledoc false

  alias Pincer.Core.Onboard.Defaults
  alias Pincer.Infra.SQLite

  @type preflight_issue :: %{
          id: atom(),
          message: String.t(),
          hint: String.t()
        }

  @spec preflight(map()) :: :ok | {:error, [preflight_issue()]}
  def preflight(config) when is_map(config) do
    issues =
      []
      |> maybe_add_storage_issue(config)
      |> maybe_add_missing_provider_or_model(config)

    if issues == [], do: :ok, else: {:error, issues}
  end

  defp maybe_add_storage_issue(issues, config) do
    if Defaults.sqlite_storage_config?(config) do
      sqlite_path =
        get_in(config, ["storage", "path"]) ||
          get_in(config, ["database", "path"]) ||
          ""

      case SQLite.check_writable_path(sqlite_path) do
        :ok ->
          issues

        {:error, reason} ->
          [
            %{
              id: :invalid_sqlite_path,
              message: "storage.path is invalid or not writable (#{inspect(reason)})",
              hint:
                "Use a writable relative or absolute path inside the project, e.g. data/pincer.db"
            }
            | issues
          ]
      end
    else
      maybe_add_invalid_db_name(issues, get_in(config, ["database", "database"]))
    end
  end

  defp maybe_add_invalid_db_name(issues, db_name) do
    cond do
      not is_binary(db_name) or String.trim(db_name) == "" ->
        [
          %{
            id: :invalid_db_name,
            message: "database.database is empty or invalid",
            hint: "Use a PostgreSQL database name like pincer"
          }
          | issues
        ]

      String.contains?(db_name, "/") or String.contains?(db_name, "\\") ->
        [
          %{
            id: :invalid_db_name,
            message:
              "database.database must be a PostgreSQL database name, not a filesystem path",
            hint: "Use a database name like pincer"
          }
          | issues
        ]

      String.contains?(db_name, "..") or
          not Regex.match?(~r/^[a-zA-Z0-9_][a-zA-Z0-9_-]*$/, db_name) ->
        [
          %{
            id: :invalid_db_name,
            message: "database.database contains unsupported characters",
            hint: "Use letters, numbers, underscore or hyphen, e.g. pincer"
          }
          | issues
        ]

      true ->
        issues
    end
  end

  defp maybe_add_missing_provider_or_model(issues, config) do
    provider =
      config
      |> get_in(["llm", "provider"])
      |> normalize_string()

    cond do
      is_nil(provider) ->
        [
          %{
            id: :missing_model,
            message: "llm provider model is missing",
            hint: "Set llm.<provider>.default_model to a non-empty value"
          },
          %{
            id: :missing_provider,
            message: "llm.provider is missing",
            hint: "Set llm.provider to a non-empty provider id"
          }
          | issues
        ]

      true ->
        model =
          config
          |> get_in(["llm", provider, "default_model"])
          |> normalize_string()

        if is_nil(model) do
          [
            %{
              id: :missing_model,
              message: "llm provider model is missing",
              hint: "Set llm.#{provider}.default_model to a non-empty value"
            }
            | issues
          ]
        else
          issues
        end
    end
  end

  @doc """
  Verifies storage backend readiness (`SQLite.health_check/0` or raw PostgreSQL TCP probe).
  Returns `:ok` or `{:warn, message}` — never blocks onboard, just warns.
  """
  @spec check_db_connectivity(map()) :: :ok | {:warn, String.t()}
  def check_db_connectivity(config) do
    if Defaults.sqlite_storage_config?(config) do
      path = Defaults.sqlite_path(config)

      with :ok <- SQLite.check_writable_path(path),
           :ok <- SQLite.health_check() do
        :ok
      else
        {:error, reason} ->
          {:warn, "SQLite indisponível em #{path} (#{inspect(reason)})."}
      end
    else
      host = get_in(config, ["database", "hostname"]) || "localhost"
      port = get_in(config, ["database", "port"]) || 5432
      port = if is_binary(port), do: String.to_integer(port), else: port
      host_charlist = String.to_charlist(host)

      case :gen_tcp.connect(host_charlist, port, [], 2000) do
        {:ok, socket} ->
          :gen_tcp.close(socket)
          :ok

        {:error, reason} ->
          {:warn,
           "PostgreSQL inacessível em #{host}:#{port} (#{reason}).\n" <>
             "   Para iniciar: docker compose up -d postgres\n" <>
             "   Após iniciar, execute: mix ecto.create && mix ecto.migrate"}
      end
    end
  end

  defp normalize_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_string(_), do: nil
end
