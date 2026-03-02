defmodule Pincer.Core.ChannelInteractionPolicyTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.ChannelInteractionPolicy

  describe "payload builders" do
    test "builds provider selector payload within channel limits" do
      assert {:ok, "select_provider:z_ai"} =
               ChannelInteractionPolicy.provider_selector_id(:telegram, "z_ai")

      assert {:ok, "select_provider:z_ai"} =
               ChannelInteractionPolicy.provider_selector_id(:discord, "z_ai")
    end

    test "rejects model selector payload above telegram limit" do
      long_model = String.duplicate("m", 80)

      assert {:error, :payload_too_large} =
               ChannelInteractionPolicy.model_selector_id(:telegram, "z_ai", long_model)
    end

    test "builds model selector payload at discord-safe size" do
      model = String.duplicate("x", 70)

      assert {:ok, payload} =
               ChannelInteractionPolicy.model_selector_id(:discord, "z_ai", model)

      assert byte_size(payload) <= 100
      assert payload == "select_model:z_ai:#{model}"
    end
  end

  describe "parse/2" do
    test "parses supported actions" do
      assert {:ok, {:select_provider, "z_ai"}} =
               ChannelInteractionPolicy.parse(:telegram, "select_provider:z_ai")

      assert {:ok, {:select_model, "z_ai", "glm-4.7"}} =
               ChannelInteractionPolicy.parse(:discord, "select_model:z_ai:glm-4.7")

      assert {:ok, :back_to_providers} =
               ChannelInteractionPolicy.parse(:telegram, "back_to_providers")

      assert {:ok, :show_menu} = ChannelInteractionPolicy.parse(:discord, "show_menu")
    end

    test "rejects malformed payloads and empty fields" do
      assert {:error, :invalid_payload} = ChannelInteractionPolicy.parse(:telegram, nil)

      assert {:error, :invalid_payload} =
               ChannelInteractionPolicy.parse(:telegram, "select_provider:")

      assert {:error, :invalid_payload} =
               ChannelInteractionPolicy.parse(:discord, "select_model::")

      assert {:error, :invalid_payload} =
               ChannelInteractionPolicy.parse(:discord, "unknown_action")
    end

    test "rejects payload above channel limit" do
      oversized = String.duplicate("a", 101)
      assert {:error, :payload_too_large} = ChannelInteractionPolicy.parse(:discord, oversized)
    end
  end
end
