defmodule Pincer.Core.MemoryTypes do
  @moduledoc """
  Canonical memory-type vocabulary for semantic memory entries.
  """

  @types ~w(reference technical_fact bug_solution user_preference architecture_decision session_summary conversation code decision pattern)

  @doc """
  Returns the canonical string form for a memory type.
  Unknown values fall back to `reference`.
  """
  @spec normalize(String.t() | atom() | nil) :: String.t()
  def normalize(type) when is_atom(type), do: type |> Atom.to_string() |> normalize()
  def normalize(nil), do: "reference"

  def normalize(type) when is_binary(type) do
    candidate =
      type
      |> String.trim()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "_")
      |> String.trim("_")

    if candidate in @types, do: candidate, else: "reference"
  end

  def normalize(_), do: "reference"

  @doc """
  Returns whether a memory type is supported.
  """
  @spec valid?(String.t() | atom() | nil) :: boolean()
  def valid?(type) when is_atom(type), do: type |> Atom.to_string() |> valid?()
  def valid?(nil), do: false

  def valid?(type) when is_binary(type) do
    candidate =
      type
      |> String.trim()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "_")
      |> String.trim("_")

    candidate in @types
  end

  def valid?(_), do: false

  @doc """
  Supported memory types.
  """
  @spec all() :: [String.t()]
  def all, do: @types
end
