defmodule Pincer.Core.Bindings do
  @moduledoc """
  Canonical binding layer between external principals and internal agent IDs.

  This module normalizes identities such as `telegram:user:123` and bridges
  them to the existing pairing persistence layer.
  """

  alias Pincer.Core.Pairing

  @type principal_ref :: String.t()
  @type conversation_ref :: String.t()

  @doc """
  Builds a normalized external principal reference.
  """
  @spec principal_ref(atom() | String.t(), atom() | String.t(), term()) :: principal_ref()
  def principal_ref(channel, kind, external_id) do
    [normalize_segment(channel), normalize_segment(kind), normalize_segment(external_id)]
    |> Enum.join(":")
  end

  @doc """
  Builds a normalized conversation reference.
  """
  @spec conversation_ref(atom() | String.t(), atom() | String.t(), term()) :: conversation_ref()
  def conversation_ref(channel, kind, external_id) do
    [normalize_segment(channel), normalize_segment(kind), normalize_segment(external_id)]
    |> Enum.join(":")
  end

  @doc """
  Binds a normalized principal reference to a root-agent id.
  """
  @spec bind(principal_ref(), String.t(), keyword()) :: :ok | {:error, :invalid_principal_ref}
  def bind(principal_ref, agent_id, opts \\ [])

  def bind(principal_ref, agent_id, opts) when is_binary(principal_ref) and is_binary(agent_id) do
    with {:ok, {channel, external_id}} <- parse_principal_ref(principal_ref) do
      Pairing.bind(channel, external_id, agent_id, opts)
    end
  end

  def bind(_principal_ref, _agent_id, _opts), do: {:error, :invalid_principal_ref}

  @doc """
  Resolves a normalized principal reference to a bound root-agent id.
  """
  @spec resolve(principal_ref()) :: String.t() | nil
  def resolve(principal_ref) when is_binary(principal_ref) do
    with {:ok, {channel, external_id}} <- parse_principal_ref(principal_ref) do
      Pairing.bound_agent_id(channel, external_id)
    else
      _ -> nil
    end
  end

  @doc """
  Returns whether a principal reference is currently paired.
  """
  @spec paired?(principal_ref()) :: boolean()
  def paired?(principal_ref) when is_binary(principal_ref) do
    with {:ok, {channel, external_id}} <- parse_principal_ref(principal_ref) do
      Pairing.paired?(channel, external_id)
    else
      _ -> false
    end
  end

  @doc """
  Parses a principal reference back into channel and external identity.
  """
  @spec parse_principal_ref(principal_ref()) ::
          {:ok, {atom(), String.t()}} | {:error, :invalid_principal_ref}
  def parse_principal_ref(principal_ref) when is_binary(principal_ref) do
    case String.split(principal_ref, ":", parts: 3) do
      [channel, _kind, external_id] when external_id != "" ->
        {:ok, {String.to_atom(channel), external_id}}

      _ ->
        {:error, :invalid_principal_ref}
    end
  end

  def parse_principal_ref(_), do: {:error, :invalid_principal_ref}

  defp normalize_segment(segment) do
    segment
    |> to_string()
    |> String.trim()
  end
end
