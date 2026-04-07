defmodule Pincer.Core.Session.Preferences do
  @moduledoc """
  File-based persistence for session preferences.

  Saves/restores user preferences (model, thinking level, reasoning visibility, etc.)
  so they survive restarts. Stored as JSON in the workspace `.pincer/` directory.
  """

  @filename "preferences.json"

  @type prefs :: %{
          model_override: map() | nil,
          thinking_level: String.t() | nil,
          reasoning_visible: boolean(),
          usage_display: String.t(),
          token_usage_total: map()
        }

  @spec save(String.t(), prefs()) :: :ok | {:error, term()}
  def save(workspace_path, prefs) when is_binary(workspace_path) do
    path = path(workspace_path)

    data = %{
      model_override: prefs.model_override,
      thinking_level: prefs.thinking_level,
      reasoning_visible: prefs.reasoning_visible,
      usage_display: prefs.usage_display,
      token_usage_total: prefs.token_usage_total,
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

  @spec load(String.t()) :: prefs()
  def load(workspace_path) when is_binary(workspace_path) do
    path = path(workspace_path)

    case File.read(path) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, data} ->
            %{
              model_override: data["model_override"],
              thinking_level: data["thinking_level"],
              reasoning_visible: data["reasoning_visible"] || false,
              usage_display: data["usage_display"] || "off",
              token_usage_total: data["token_usage_total"] || default_token_usage()
            }

          {:error, _} ->
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
      token_usage_total: default_token_usage()
    }
  end

  defp default_token_usage, do: %{"prompt_tokens" => 0, "completion_tokens" => 0}

  defp path(workspace_path) do
    Path.join([workspace_path, ".pincer", @filename])
  end
end
