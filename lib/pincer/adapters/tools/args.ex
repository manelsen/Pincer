defmodule Pincer.Adapters.Tools.Args do
  @moduledoc "Common argument and context checks for tool adapters."

  @type string_mode :: :raw | :nonempty | :nonblank | :trimmed

  @doc "Validates a string in the selected mode. Only `:trimmed` changes the string."
  @spec string(term(), string_mode()) ::
          {:ok, String.t()} | {:error, :missing | :invalid | :empty}
  def string(value, :trimmed) when is_binary(value), do: string(String.trim(value), :nonempty)

  def string(value, :nonblank) when is_binary(value) do
    if String.trim(value) == "", do: {:error, :empty}, else: {:ok, value}
  end

  def string("", :nonempty), do: {:error, :empty}
  def string(value, mode) when is_binary(value) and mode in [:raw, :nonempty], do: {:ok, value}
  def string(nil, _mode), do: {:error, :missing}
  def string(_value, _mode), do: {:error, :invalid}

  @doc "Reads a string key or its existing atom equivalent. A string-keyed `false` is preserved."
  @spec get(map(), String.t()) :: term()
  def get(args, key) when is_map(args) and is_binary(key) do
    case Map.get(args, key) do
      nil -> get_existing_atom(args, key)
      value -> value
    end
  end

  @doc "Returns the context workspace, invoking the tool's fallback only when it is absent."
  @spec workspace_root(map(), (-> String.t())) :: term()
  def workspace_root(context, fallback \\ &File.cwd!/0) do
    Map.get(context, "workspace_path") || Map.get(context, :workspace_path) || fallback.()
  end

  @doc "Reads the session identifier from either tool context key."
  @spec session_id(map()) :: term()
  def session_id(context), do: Map.get(context, "session_id") || Map.get(context, :session_id)

  defp get_existing_atom(args, key) do
    Map.get(args, String.to_existing_atom(key))
  rescue
    ArgumentError -> nil
  end
end
