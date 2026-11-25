defmodule PincerPorts.Structs.Usage do
  @moduledoc """
  Normalized token usage accounting struct across LLM providers, Executor,
  session preferences, and channel adapters.
  """

  defstruct prompt_tokens: 0, completion_tokens: 0, total_tokens: 0

  @type t :: %__MODULE__{
          prompt_tokens: non_neg_integer(),
          completion_tokens: non_neg_integer(),
          total_tokens: non_neg_integer()
        }

  @doc """
  Builds a `%Usage{}` struct from a map, keyword list, existing struct, or `nil`.
  """
  @spec new(t() | map() | keyword() | nil) :: t()
  def new(attrs \\ %{})
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> normalize()
  def new(attrs), do: normalize(attrs)

  @doc """
  Normalizes raw provider/persisted usage payloads into `%Usage{}`.
  Returns a zeroed `%Usage{}` for `nil` or non-map inputs.
  """
  @spec normalize(term()) :: t()
  def normalize(%__MODULE__{} = usage) do
    prompt = non_neg_int(usage.prompt_tokens)
    completion = non_neg_int(usage.completion_tokens)
    raw_total = non_neg_int(usage.total_tokens)
    total = if raw_total > 0, do: raw_total, else: prompt + completion

    %__MODULE__{prompt_tokens: prompt, completion_tokens: completion, total_tokens: total}
  end

  def normalize(raw) when is_map(raw) do
    prompt =
      raw
      |> read_any([:prompt_tokens, "prompt_tokens", :input_tokens, "input_tokens"])
      |> non_neg_int()

    completion =
      raw
      |> read_any([:completion_tokens, "completion_tokens", :output_tokens, "output_tokens"])
      |> non_neg_int()

    raw_total =
      raw
      |> read_any([:total_tokens, "total_tokens"])
      |> non_neg_int()

    total = if raw_total > 0, do: raw_total, else: prompt + completion

    %__MODULE__{prompt_tokens: prompt, completion_tokens: completion, total_tokens: total}
  end

  def normalize(_other), do: %__MODULE__{}

  @doc """
  Normalizes raw usage into `%Usage{}`, preserving `nil` when no accounting was supplied.
  """
  @spec normalize_optional(term()) :: t() | nil
  def normalize_optional(nil), do: nil
  def normalize_optional(raw), do: normalize(raw)

  @doc """
  Sums two `%Usage{}` structs.
  """
  @spec add(t(), t()) :: t()
  def add(%__MODULE__{} = a, %__MODULE__{} = b) do
    prompt = a.prompt_tokens + b.prompt_tokens
    completion = a.completion_tokens + b.completion_tokens
    total = max(prompt + completion, a.total_tokens + b.total_tokens)

    %__MODULE__{
      prompt_tokens: prompt,
      completion_tokens: completion,
      total_tokens: total
    }
  end

  @doc """
  Converts `%Usage{}` to a canonical string-keyed map for JSON serialization.
  """
  @spec to_map(t()) :: %{String.t() => non_neg_integer()}
  def to_map(%__MODULE__{} = usage) do
    %{
      "prompt_tokens" => usage.prompt_tokens,
      "completion_tokens" => usage.completion_tokens,
      "total_tokens" => usage.total_tokens
    }
  end

  defp read_any(_map, []), do: nil

  defp read_any(map, [key | rest]) do
    case Map.get(map, key) do
      nil -> read_any(map, rest)
      val -> val
    end
  end

  defp non_neg_int(val) when is_integer(val), do: max(val, 0)
  defp non_neg_int(val) when is_float(val), do: max(trunc(val), 0)

  defp non_neg_int(val) when is_binary(val) do
    case Integer.parse(String.trim(val)) do
      {int, ""} -> max(int, 0)
      _ -> 0
    end
  end

  defp non_neg_int(_), do: 0
end
