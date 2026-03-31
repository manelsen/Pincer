defmodule Pincer.Core.CapabilitiesTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.Capabilities

  test "schema version is explicit" do
    assert Capabilities.schema_version() == "1.0"
  end

  test "validates provider capabilities with expected fields" do
    provider_caps = %{
      streaming: true,
      tool_calling: :native,
      multimodal: [:image, :audio],
      max_context: 128_000,
      structured_output: true,
      retry_profile: :aggressive
    }

    assert :ok = Capabilities.validate(:provider, provider_caps)
  end

  test "returns validation errors when required fields are missing" do
    assert {:error, errors} = Capabilities.validate(:tool, %{network: true})
    assert Enum.any?(errors, &(&1.code == :missing_required_field and &1.field == :filesystem))

    assert Enum.any?(
             errors,
             &(&1.code == :missing_required_field and &1.field == :side_effect_level)
           )
  end

  test "query API filters entries by adapter type and feature" do
    catalog = [
      %{
        adapter: :openrouter,
        type: :provider,
        capabilities: %{streaming: true, tool_calling: :native}
      },
      %{
        adapter: :safe_shell,
        type: :tool,
        capabilities: %{filesystem: true, network: false, writes_state: true}
      },
      %{
        adapter: :discord,
        type: :channel,
        capabilities: %{buttons: true, markdown_html: true, attachments: true}
      }
    ]

    assert [%{adapter: :openrouter}] =
             Capabilities.query(catalog, type: :provider, feature: :streaming)

    assert [%{adapter: :discord}] =
             Capabilities.query(catalog, type: :channel, feature: :attachments)
  end

  test "provider declarations are explicit and schema-valid" do
    providers = Capabilities.declarations(:provider)

    assert Enum.any?(providers, &(&1.adapter == :openrouter))
    assert Enum.any?(providers, &(&1.adapter == :google))

    assert Enum.all?(providers, fn entry ->
             :ok == Capabilities.validate(:provider, entry.capabilities)
           end)
  end

  test "tool declarations include risk metadata and validate against schema" do
    tools = Capabilities.declarations(:tool)

    assert Enum.any?(tools, &(&1.adapter == :safe_shell))
    assert Enum.all?(tools, &Map.has_key?(&1.capabilities, :side_effect_level))

    assert Enum.all?(tools, fn entry ->
             :ok == Capabilities.validate(:tool, entry.capabilities)
           end)
  end

  test "channel declarations expose ux and streaming capabilities" do
    channels = Capabilities.declarations(:channel)

    assert Enum.any?(channels, &(&1.adapter == :telegram))
    assert Enum.all?(channels, &Map.has_key?(&1.capabilities, :attachments))
    assert Enum.all?(channels, &Map.has_key?(&1.capabilities, :streaming_support))

    assert Enum.all?(channels, fn entry ->
             :ok == Capabilities.validate(:channel, entry.capabilities)
           end)
  end
end
