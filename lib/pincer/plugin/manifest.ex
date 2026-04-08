defmodule Pincer.Plugin.Manifest do
  @moduledoc """
  Parseia e valida manifests YAML de plugins Pincer.

  Cada plugin declara um arquivo `pincer_plugin.yaml` descrevendo sua
  identidade, tipo e schema de configuração. O manifest é lido sem executar
  código do plugin — apenas o YAML é avaliado.

  ## Formato

      id: telegram
      name: Pincer Telegram
      version: "0.1.0"
      kind: channel          # channel | storage | llm | tool
      adapter: "Pincer.Channels.Telegram"
      description: "Telegram channel adapter"
      config_schema:
        token_env:
          type: string
          required: true

  ## Descoberta

  Em modo monorepo os manifests ficam em `priv/plugins/<id>/pincer_plugin.yaml`.
  Quando os plugins forem pacotes Hex separados, cada um trará o arquivo
  em `priv/pincer_plugin.yaml` (acessível via `:code.priv_dir/1`).
  """

  @valid_kinds ~w(channel storage llm tool)

  defstruct [
    :id,
    :name,
    :version,
    :kind,
    :adapter,
    :description,
    config_schema: %{}
  ]

  @type kind :: :channel | :storage | :llm | :tool

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          version: String.t(),
          kind: kind(),
          adapter: module() | nil,
          description: String.t() | nil,
          config_schema: map()
        }

  @doc """
  Parseia uma string YAML e retorna `{:ok, manifest}` ou `{:error, reason}`.
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, String.t()}
  def parse(yaml) when is_binary(yaml) do
    with {:ok, data} <- decode_yaml(yaml),
         {:ok, manifest} <- validate(data) do
      {:ok, manifest}
    end
  end

  @doc """
  Lê um arquivo YAML e retorna `{:ok, manifest}` ou `{:error, reason}`.
  """
  @spec from_file(Path.t()) :: {:ok, t()} | {:error, String.t()}
  def from_file(path) do
    case File.read(path) do
      {:ok, content} -> parse(content)
      {:error, :enoent} -> {:error, "Manifest not found: #{path}"}
      {:error, reason} -> {:error, "Failed to read #{path}: #{inspect(reason)}"}
    end
  end

  @doc """
  Descobre todos os manifests instalados.

  Em modo monorepo lê `priv/plugins/*/pincer_plugin.yaml`.
  Também verifica `priv/pincer_plugin.yaml` de cada dep Hex que o declare.
  """
  @spec discover() :: [t()]
  def discover do
    (discover_from_priv_plugins() ++ discover_from_hex_deps())
    |> Enum.uniq_by(& &1.id)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp decode_yaml(yaml) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, data} when is_map(data) -> {:ok, data}
      {:ok, _} -> {:error, "Manifest YAML must be a map at the top level"}
      {:error, reason} -> {:error, "Invalid YAML: #{inspect(reason)}"}
    end
  end

  defp validate(data) do
    with {:ok, id} <- require_string(data, "id"),
         {:ok, name} <- require_string(data, "name"),
         {:ok, kind} <- parse_kind(data),
         version = Map.get(data, "version", "0.0.0"),
         adapter = parse_adapter(Map.get(data, "adapter")),
         description = Map.get(data, "description"),
         config_schema = Map.get(data, "config_schema", %{}) || %{} do
      {:ok,
       %__MODULE__{
         id: id,
         name: name,
         version: to_string(version),
         kind: kind,
         adapter: adapter,
         description: description,
         config_schema: config_schema
       }}
    end
  end

  defp require_string(data, key) do
    case Map.get(data, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      nil -> {:error, "Missing required field: #{key}"}
      _ -> {:error, "Field #{key} must be a non-empty string"}
    end
  end

  defp parse_kind(data) do
    case Map.get(data, "kind") do
      kind when kind in @valid_kinds ->
        {:ok, String.to_atom(kind)}

      nil ->
        {:error, "Missing required field: kind (must be one of: #{Enum.join(@valid_kinds, ", ")})"}

      other ->
        {:error,
         "Invalid kind: #{inspect(other)}. Must be one of: #{Enum.join(@valid_kinds, ", ")}"}
    end
  end

  defp parse_adapter(nil), do: nil

  defp parse_adapter(adapter) when is_binary(adapter) do
    case Module.safe_concat([adapter]) do
      module when is_atom(module) -> module
    end
  rescue
    ArgumentError -> nil
  end

  defp discover_from_priv_plugins do
    priv = Application.app_dir(:pincer, "priv")
    pattern = Path.join([priv, "plugins", "*", "pincer_plugin.yaml"])

    pattern
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      case from_file(path) do
        {:ok, manifest} -> [manifest]
        {:error, _} -> []
      end
    end)
  end

  defp discover_from_hex_deps do
    :code.get_path()
    |> Enum.flat_map(fn beam_path ->
      priv_candidate =
        beam_path
        |> Path.dirname()
        |> then(fn ebin ->
          Path.join([Path.dirname(ebin), "priv", "pincer_plugin.yaml"])
        end)

      case from_file(priv_candidate) do
        {:ok, manifest} -> [manifest]
        {:error, _} -> []
      end
    end)
  end
end
