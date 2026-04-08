defmodule Pincer.Core.Onboard.Preflight do
  @moduledoc false

  @type preflight_issue :: %{
          id: atom(),
          message: String.t(),
          hint: String.t()
        }

  @spec preflight(map()) :: :ok | {:error, [preflight_issue()]}
  def preflight(config) when is_map(config) do
    issues =
      []
      |> maybe_add_invalid_db_name(get_in(config, ["database", "database"]))
      |> maybe_add_missing_provider_or_model(config)

    if issues == [], do: :ok, else: {:error, issues}
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
  Attempts a raw TCP connection to the configured PostgreSQL host/port.
  Returns :ok or {:warn, message} — never blocks onboard, just warns.
  """
  @spec check_db_connectivity(map()) :: :ok | {:warn, String.t()}
  def check_db_connectivity(config) do
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

  defp normalize_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_string(_), do: nil
end
