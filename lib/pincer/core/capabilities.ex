defmodule Pincer.Core.Capabilities do
  @moduledoc """
  Versioned capability schema for providers, tools, and channels.
  """

  @schema_version "1.0"

  @provider_required [
    :streaming,
    :tool_calling,
    :multimodal,
    :max_context,
    :structured_output,
    :retry_profile
  ]
  @tool_required [:filesystem, :network, :writes_state, :requires_approval, :side_effect_level]
  @channel_required [:buttons, :markdown_html, :attachments, :streaming_support]

  @type adapter_type :: :provider | :tool | :channel
  @type validation_error :: %{code: :missing_required_field, field: atom(), message: String.t()}

  @doc "Returns the current schema version."
  @spec schema_version() :: String.t()
  def schema_version, do: @schema_version

  @doc """
  Validates capabilities against required fields for a given adapter type.
  """
  @spec validate(adapter_type(), map()) :: :ok | {:error, [validation_error()]}
  def validate(type, capabilities)
      when type in [:provider, :tool, :channel] and is_map(capabilities) do
    type
    |> required_fields()
    |> Enum.reduce([], fn field, errors ->
      if Map.has_key?(capabilities, field) do
        errors
      else
        [
          %{
            code: :missing_required_field,
            field: field,
            message: "required field #{field} is missing"
          }
          | errors
        ]
      end
    end)
    |> case do
      [] -> :ok
      errors -> {:error, Enum.reverse(errors)}
    end
  end

  def validate(_type, _capabilities) do
    {:error,
     [
       %{
         code: :missing_required_field,
         field: :type,
         message: "invalid adapter type"
       }
     ]}
  end

  @doc """
  Filters a capability catalog by adapter type and feature key.
  """
  @spec query([map()], keyword()) :: [map()]
  def query(catalog, opts \\ []) when is_list(catalog) and is_list(opts) do
    type = Keyword.get(opts, :type)
    feature = Keyword.get(opts, :feature)

    Enum.filter(catalog, fn entry ->
      type_matches?(entry, type) and feature_matches?(entry, feature)
    end)
  end

  defp required_fields(:provider), do: @provider_required
  defp required_fields(:tool), do: @tool_required
  defp required_fields(:channel), do: @channel_required

  defp type_matches?(_entry, nil), do: true
  defp type_matches?(entry, type), do: Map.get(entry, :type) == type

  defp feature_matches?(_entry, nil), do: true

  defp feature_matches?(entry, feature) do
    case Map.get(entry, :capabilities) do
      capabilities when is_map(capabilities) ->
        case Map.fetch(capabilities, feature) do
          :error -> false
          {:ok, false} -> false
          {:ok, nil} -> false
          {:ok, _value} -> true
        end

      _ ->
        false
    end
  end
end
