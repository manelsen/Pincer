defmodule Pincer.LLM.RetrySettings do
  @moduledoc """
  Reads the `:pincer, :llm_retry` application config into the retry budget used
  by `Pincer.LLM.Client`.

  The config may be a keyword list, a list of `{key, value}`/map entries, or a
  map. Unusable values fall back to the module defaults instead of raising, so a
  malformed entry degrades the retry budget rather than the boot.
  """

  @default_max_retries 5
  @default_initial_backoff 2_000
  @default_max_backoff 30_000
  @default_jitter_ratio 0.20
  @default_max_elapsed_ms 120_000

  @type t :: %{
          max_retries: pos_integer(),
          initial_backoff: pos_integer(),
          max_backoff: pos_integer(),
          max_elapsed_ms: pos_integer(),
          jitter_ratio: float()
        }

  @doc """
  Returns the normalized retry budget, reading `:pincer, :llm_retry` by default.
  """
  @spec load(keyword() | map()) :: t()
  def load(config \\ Application.get_env(:pincer, :llm_retry, [])) do
    %{
      max_retries:
        positive_integer(fetch(config, :max_retries, @default_max_retries), @default_max_retries),
      initial_backoff:
        positive_integer(
          fetch(config, :initial_backoff, @default_initial_backoff),
          @default_initial_backoff
        ),
      max_backoff:
        positive_integer(fetch(config, :max_backoff, @default_max_backoff), @default_max_backoff),
      max_elapsed_ms:
        positive_integer(
          fetch(config, :max_elapsed_ms, @default_max_elapsed_ms),
          @default_max_elapsed_ms
        ),
      jitter_ratio:
        float_in_range(
          fetch(config, :jitter_ratio, @default_jitter_ratio),
          0.0,
          1.0,
          @default_jitter_ratio
        )
    }
  end

  @doc """
  Returns the configured value for `key`, or `default` when it is absent.
  """
  @spec fetch(keyword() | map() | list(), atom(), term()) :: term()
  def fetch(config, _key, default) when not is_list(config) and not is_map(config), do: default

  def fetch(config, key, default) when is_list(config) do
    string_key = to_string(key)

    cond do
      Keyword.keyword?(config) ->
        Keyword.get(config, key, default)

      true ->
        Enum.find_value(config, default, fn
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

  def fetch(config, key, default) when is_map(config), do: Map.get(config, key, default)

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default

  defp float_in_range(value, min_value, max_value, _default)
       when is_float(value) and value >= min_value and value <= max_value,
       do: value

  defp float_in_range(value, min_value, max_value, _default)
       when is_integer(value) and value >= min_value and value <= max_value,
       do: value / 1

  defp float_in_range(_value, _min, _max, default), do: default
end
