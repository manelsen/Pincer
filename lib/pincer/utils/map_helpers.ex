defmodule Pincer.Utils.MapHelpers do
  @moduledoc false

  @doc "Looks up key in map by atom or string form, atom takes precedence."
  def read_field(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  def read_field(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) ||
      case safe_atom(key) do
        nil -> nil
        atom -> Map.get(map, atom)
      end
  end

  def read_field(_map, _key), do: nil

  @doc "Returns true if value is a non-blank binary, or a non-empty list/map."
  def present?(value) when is_binary(value), do: String.trim(value) != ""
  def present?(value) when is_list(value), do: value != []
  def present?(value) when is_map(value), do: map_size(value) > 0
  def present?(_), do: false

  @doc "Coerces truthy: true/\"true\"/1 → true, everything else → false."
  def truthy?(true), do: true
  def truthy?("true"), do: true
  def truthy?(1), do: true
  def truthy?(_), do: false

  defp safe_atom(str) when is_binary(str) do
    String.to_existing_atom(str)
  rescue
    ArgumentError -> nil
  end
end
