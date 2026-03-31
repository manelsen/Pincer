defmodule Pincer.Utils.Value do
  @moduledoc """
  Shared value normalization and mixed container field access helpers.
  """

  @spec fetch(term(), atom(), term()) :: term()
  def fetch(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  def fetch(list, key, default) when is_list(list) and is_atom(key) do
    string_key = Atom.to_string(key)

    cond do
      Keyword.keyword?(list) ->
        Keyword.get(list, key, default)

      true ->
        Enum.find_value(list, default, fn
          {^key, value} ->
            value

          {list_key, value} when is_binary(list_key) and list_key == string_key ->
            value

          {list_key, value} when is_atom(list_key) ->
            if Atom.to_string(list_key) == string_key, do: value, else: nil

          %{} = map ->
            Map.get(map, key) || Map.get(map, string_key)

          _ ->
            nil
        end)
    end
  end

  def fetch(_other, _key, default), do: default

  @spec trim_to_nil(term()) :: String.t() | nil
  def trim_to_nil(nil), do: nil

  def trim_to_nil(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      text -> text
    end
  end

  @spec trim_string(term()) :: String.t() | nil
  def trim_string(nil), do: nil

  def trim_string(value) do
    value
    |> to_string()
    |> String.trim()
  end
end
