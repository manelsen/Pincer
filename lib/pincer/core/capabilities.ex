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
  @type declaration :: %{adapter: atom(), type: adapter_type(), capabilities: map()}

  @declarations [
    %{
      adapter: :openrouter,
      type: :provider,
      capabilities: %{
        streaming: true,
        tool_calling: :native,
        multimodal: [:image],
        max_context: 128_000,
        structured_output: true,
        retry_profile: :aggressive
      }
    },
    %{
      adapter: :google,
      type: :provider,
      capabilities: %{
        streaming: true,
        tool_calling: :native,
        multimodal: [:image, :audio],
        max_context: 1_000_000,
        structured_output: true,
        retry_profile: :balanced
      }
    },
    %{
      adapter: :safe_shell,
      type: :tool,
      capabilities: %{
        filesystem: true,
        network: false,
        writes_state: true,
        requires_approval: true,
        side_effect_level: :privileged
      }
    },
    %{
      adapter: :web,
      type: :tool,
      capabilities: %{
        filesystem: false,
        network: true,
        writes_state: false,
        requires_approval: false,
        side_effect_level: :read
      }
    },
    %{
      adapter: :file_system,
      type: :tool,
      capabilities: %{
        filesystem: true,
        network: false,
        writes_state: true,
        requires_approval: true,
        side_effect_level: :guarded_write
      }
    },
    %{
      adapter: :telegram,
      type: :channel,
      capabilities: %{
        buttons: true,
        markdown_html: true,
        attachments: true,
        streaming_support: true
      }
    },
    %{
      adapter: :discord,
      type: :channel,
      capabilities: %{
        buttons: true,
        markdown_html: true,
        attachments: true,
        streaming_support: true
      }
    },
    %{
      adapter: :cli,
      type: :channel,
      capabilities: %{
        buttons: false,
        markdown_html: false,
        attachments: true,
        streaming_support: true
      }
    }
  ]

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

  @doc """
  Returns declared adapter capabilities.
  """
  @spec declarations(adapter_type() | :all) :: [declaration()]
  def declarations(type \\ :all)

  def declarations(:all), do: @declarations

  def declarations(type) when type in [:provider, :tool, :channel],
    do: query(@declarations, type: type)

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
