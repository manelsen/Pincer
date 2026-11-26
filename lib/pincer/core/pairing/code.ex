defmodule Pincer.Core.Pairing.Code do
  @moduledoc """
  Code generation, cryptographic hashing, constant-time verification, and
  normalization helpers for the pairing workflow.
  """

  alias Pincer.Core.AgentRegistry
  alias Pincer.Utils.Time

  @default_ttl_ms 300_000
  @default_max_attempts 5
  @default_code_length 6

  @doc """
  Normalizes a pairing or invite code by trimming whitespace and uppercasing.
  """
  @spec normalize_code(term()) :: String.t()
  def normalize_code(code) do
    code
    |> to_string()
    |> String.trim()
    |> String.upcase()
  end

  @doc """
  Computes the SHA-256 digest of a normalized pairing or invite code.
  """
  @spec hash_code(term()) :: binary()
  def hash_code(code) do
    code
    |> normalize_code()
    |> then(&:crypto.hash(:sha256, &1))
  end

  @doc """
  Verifies a candidate `code` against an `expected_hash` in constant time.
  """
  @spec verify?(term(), term()) :: boolean()
  def verify?(expected_hash, code) when is_binary(expected_hash) do
    candidate = hash_code(code)

    byte_size(candidate) == byte_size(expected_hash) and
      :crypto.hash_equals(candidate, expected_hash)
  end

  def verify?(_expected_hash, _code), do: false

  @doc """
  Generates a normalized one-time pairing code, optionally using `:code_generator`.
  """
  @spec generate_code(keyword()) :: String.t()
  def generate_code(opts \\ []) do
    generate_with(opts, &default_code/0)
  end

  @doc """
  Generates a normalized invite code, optionally using `:code_generator`.
  """
  @spec generate_invite_code(keyword()) :: String.t()
  def generate_invite_code(opts \\ []) do
    generate_with(opts, &default_invite_code/0)
  end

  @doc """
  Normalizes a channel name to a lowercase trimmed string.
  """
  @spec normalize_channel(term()) :: String.t()
  def normalize_channel(channel) do
    channel
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  @doc """
  Normalizes a sender identifier to a trimmed string.
  """
  @spec normalize_sender(term()) :: String.t()
  def normalize_sender(sender_id) do
    sender_id
    |> to_string()
    |> String.trim()
  end

  @doc """
  Builds the composite `{channel, sender_id}` lookup key.
  """
  @spec key(term(), term()) :: {String.t(), String.t()}
  def key(channel, sender_id) do
    {normalize_channel(channel), normalize_sender(sender_id)}
  end

  @doc """
  Builds the composite `{channel, code_hash}` invite lookup key.
  """
  @spec invite_key(term(), term()) :: {String.t(), binary()}
  def invite_key(channel, code) do
    {normalize_channel(channel), hash_code(code)}
  end

  @doc """
  Validates and normalizes an explicit `agent_id` according to `AgentRegistry`.
  """
  @spec normalize_explicit_agent_id(term(), keyword()) ::
          {:ok, String.t() | nil} | {:error, {:invalid_agent_id, String.t()}}
  def normalize_explicit_agent_id(agent_id, opts \\ []) do
    allow_nil? = Keyword.get(opts, :allow_nil?, false)
    candidate = normalize_trimmed_agent_id(agent_id)

    cond do
      is_nil(candidate) and allow_nil? ->
        {:ok, nil}

      is_nil(candidate) ->
        {:error, {:invalid_agent_id, "Invalid agent_id #{inspect(agent_id)}: cannot be empty"}}

      true ->
        try do
          {:ok, AgentRegistry.normalize_agent_id!(candidate)}
        rescue
          error in ArgumentError -> {:error, {:invalid_agent_id, Exception.message(error)}}
        end
    end
  end

  @doc """
  Normalizes a stored `agent_id`, returning `nil` if empty or invalid.
  """
  @spec normalize_stored_agent_id(term()) :: String.t() | nil
  def normalize_stored_agent_id(agent_id) do
    case normalize_trimmed_agent_id(agent_id) do
      nil ->
        nil

      candidate ->
        try do
          AgentRegistry.normalize_agent_id!(candidate)
        rescue
          ArgumentError -> nil
        end
    end
  end

  @doc """
  Extracts a positive `:ttl_ms` option or falls back to the default TTL.
  """
  @spec ttl_ms(keyword()) :: pos_integer()
  def ttl_ms(opts) do
    case Keyword.get(opts, :ttl_ms, @default_ttl_ms) do
      value when is_integer(value) and value > 0 -> value
      _ -> @default_ttl_ms
    end
  end

  @doc """
  Extracts a positive `:max_attempts` option or falls back to the default limit.
  """
  @spec max_attempts(keyword()) :: pos_integer()
  def max_attempts(opts) do
    case Keyword.get(opts, :max_attempts, @default_max_attempts) do
      value when is_integer(value) and value > 0 -> value
      _ -> @default_max_attempts
    end
  end

  @doc """
  Extracts an integer `:now_ms` option or returns current monotonic milliseconds.
  """
  @spec now_ms(keyword()) :: integer()
  def now_ms(opts) do
    case Keyword.get(opts, :now_ms) do
      value when is_integer(value) -> value
      _ -> Time.monotonic_ms()
    end
  end

  @doc """
  Returns whether a pending or invite entry has expired at `now_ms`.
  """
  @spec expired?(%{expires_at_ms: integer()}, integer()) :: boolean()
  def expired?(entry, now_ms) do
    entry.expires_at_ms <= now_ms
  end

  defp generate_with(opts, fallback) do
    generator = Keyword.get(opts, :code_generator, fallback)

    case generator.() do
      value when is_binary(value) and value != "" ->
        normalize_code(value)

      value when is_integer(value) ->
        value |> Integer.to_string() |> normalize_code()

      _ ->
        fallback.()
    end
  end

  defp default_code do
    1..@default_code_length
    |> Enum.map_join(fn _ -> Integer.to_string(:rand.uniform(10) - 1) end)
    |> normalize_code()
  end

  defp default_invite_code do
    token =
      5
      |> :crypto.strong_rand_bytes()
      |> Base.encode32(padding: false)
      |> String.slice(0, 8)

    normalize_code("PAIR_#{token}")
  end

  defp normalize_trimmed_agent_id(nil), do: nil

  defp normalize_trimmed_agent_id(agent_id) do
    candidate =
      agent_id
      |> to_string()
      |> String.trim()

    if candidate == "", do: nil, else: candidate
  end
end
