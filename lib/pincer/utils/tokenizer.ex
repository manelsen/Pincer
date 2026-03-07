defmodule Pincer.Utils.Tokenizer do
  @moduledoc """
  Provides fast, heuristic-based token estimation for context window management.
  """

  @doc """
  Estimates the number of tokens in a string, map, or list.
  Uses a fast heuristic: ~4 bytes per token.
  """
  @spec estimate(any()) :: non_neg_integer()
  def estimate(data) when is_binary(data) do
    max(1, div(byte_size(data), 4))
  end

  def estimate(data) when is_map(data) or is_list(data) do
    data
    |> Jason.encode!()
    |> byte_size()
    |> div(4)
  rescue
    _ -> 0
  end

  def estimate(_), do: 0
end
