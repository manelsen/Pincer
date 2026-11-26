defmodule Pincer.Core.Session.Preferences do
  @moduledoc """
  File-based persistence for session preferences.

  Saves/restores user preferences (model, thinking level, reasoning visibility, etc.)
  so they survive restarts. Stored as JSON in the workspace `.pincer/` directory.
  """

  require Logger

  alias Pincer.Utils.ModelOverride
  alias PincerPorts.Structs.Usage

  @filename "preferences.json"

  @type model_override :: %{provider: String.t(), model: String.t()}

  @type prefs :: %{
          model_override: model_override() | nil,
          thinking_level: String.t() | nil,
          reasoning_visible: boolean(),
          usage_display: String.t(),
          token_usage_total: Usage.t()
        }

  @spec save(String.t(), prefs()) :: :ok | {:error, term()}
  def save(workspace_path, prefs) when is_binary(workspace_path) do
    path = path(workspace_path)

    data = %{
      model_override: normalize_model_override(prefs.model_override),
      thinking_level: prefs.thinking_level,
      reasoning_visible: prefs.reasoning_visible,
      usage_display: prefs.usage_display,
      token_usage_total: prefs.token_usage_total |> Usage.normalize() |> Usage.to_map(),
      saved_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    case Jason.encode(data, pretty: true) do
      {:ok, json} ->
        case File.mkdir_p(Path.dirname(path)) do
          :ok -> File.write(path, json)
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Persists preference fields from a session state map, logging warnings/errors
  instead of crashing the session process.
  """
  @spec save_state(map()) :: :ok
  def save_state(%{workspace_path: nil, session_id: session_id}) do
    Logger.warning("[SESSION] #{session_id} save_preferences skipped: workspace_path is nil")
    :ok
  end

  def save_state(state) do
    result =
      save(state.workspace_path, %{
        model_override: state.model_override,
        thinking_level: state.thinking_level,
        reasoning_visible: state.reasoning_visible,
        usage_display: state.usage_display,
        token_usage_total: state.token_usage_total
      })

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "[SESSION] #{state.session_id} save_preferences failed (workspace=#{state.workspace_path}): #{inspect(reason)}"
        )

        :ok
    end
  end

  @spec load(String.t()) :: prefs()
  def load(workspace_path) when is_binary(workspace_path) do
    path = path(workspace_path)

    case File.read(path) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, data} when is_map(data) ->
            %{
              model_override: normalize_model_override(data["model_override"]),
              thinking_level: data["thinking_level"],
              reasoning_visible: data["reasoning_visible"] || false,
              usage_display: data["usage_display"] || "off",
              token_usage_total: Usage.normalize(data["token_usage_total"])
            }

          _ ->
            defaults()
        end

      {:error, _} ->
        defaults()
    end
  end

  defp defaults do
    %{
      model_override: nil,
      thinking_level: nil,
      reasoning_visible: false,
      usage_display: "off",
      token_usage_total: %Usage{}
    }
  end

  defp normalize_model_override(override) do
    case ModelOverride.normalize(override) do
      nil -> nil
      normalized -> Map.take(normalized, [:provider, :model])
    end
  end

  defp path(workspace_path) do
    Path.join([workspace_path, ".pincer", @filename])
  end
end
