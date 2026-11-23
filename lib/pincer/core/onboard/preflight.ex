defmodule Pincer.Core.Onboard.Preflight do
  @moduledoc false

  require Logger

  alias Pincer.Core.Onboard.Defaults
  alias Pincer.Infra.SQLite

  @vec_extension_candidates [
    "priv/sqlite_vec/vec0.so",
    "priv/sqlite_vec/vec0",
    "priv/sqlite_vec/vec0.dylib"
  ]

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

    maybe_warn_missing_vector_extension(config)

    if issues == [], do: :ok, else: {:error, issues}
  end

  defp maybe_add_storage_issue(issues, config) do
    sqlite_path = Defaults.sqlite_path(config)

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
  Verifies embedded SQLite readiness (`SQLite.health_check/0`).
  Returns `:ok` or `{:warn, message}` — never blocks onboard, just warns.
  """
  @spec check_db_connectivity(map()) :: :ok | {:warn, String.t()}
  def check_db_connectivity(config) do
    path = Defaults.sqlite_path(config)

    with :ok <- SQLite.check_writable_path(path),
         :ok <- SQLite.health_check() do
      :ok
    else
      {:error, reason} ->
        {:warn, "SQLite indisponível em #{path} (#{inspect(reason)})."}
    end
  end

  defp maybe_warn_missing_vector_extension(config) do
    if vec_enabled_setting?(get_in(config, ["storage", "vec"])) do
      explicit_path = get_in(config, ["storage", "vec_path"])

      unless vec_extension_available?(explicit_path) do
        Logger.warning(
          "sqlite-vec extension not found; vector search will use cosine fallback. " <>
            "Install it under priv/sqlite_vec/ or set storage.vec_path."
        )
      end
    end
  end

  defp vec_enabled_setting?(false), do: false
  defp vec_enabled_setting?(0), do: false

  defp vec_enabled_setting?(value) when is_binary(value) do
    String.downcase(String.trim(value)) not in ["false", "off", "disabled", "none"]
  end

  defp vec_enabled_setting?(_value), do: true

  defp vec_extension_available?(explicit_path) do
    path =
      normalize_string(explicit_path) ||
        normalize_string(System.get_env("PINCER_SQLITE_VEC_PATH"))

    case path do
      nil ->
        default_vec_extension_paths()
        |> Enum.any?(&File.regular?/1)

      auto when auto in ["auto", "true", ":auto"] ->
        default_vec_extension_paths()
        |> Enum.any?(&File.regular?/1)

      path ->
        File.regular?(path)
    end
  end

  defp default_vec_extension_paths do
    priv_dir =
      case :code.priv_dir(:pincer) do
        path when is_list(path) -> List.to_string(path)
        _ -> nil
      end

    @vec_extension_candidates
    |> Enum.flat_map(fn relative ->
      [Path.expand(relative)] ++
        if(is_binary(priv_dir),
          do: [Path.join(priv_dir, Path.basename(relative))],
          else: []
        )
    end)
    |> Enum.uniq()
  end

  defp normalize_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_string(_), do: nil
end
