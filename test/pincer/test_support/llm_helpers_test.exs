defmodule Pincer.Test.Support.LLMHelpersTest do
  use ExUnit.Case, async: false

  alias Pincer.Test.Support.LLMHelpers

  test "put_providers!/1 overrides :llm_providers and restores original on exit" do
    original = Application.get_env(:pincer, :llm_providers)
    custom = %{"custom" => LLMHelpers.mock_provider_config(%{default_model: "custom-model"})}

    assert LLMHelpers.put_providers!(custom, default: "custom") == custom
    assert Application.get_env(:pincer, :llm_providers) == custom
    assert Application.get_env(:pincer, :default_llm_provider) == "custom"

    # Nested override is also valid and restores in LIFO order on exit.
    LLMHelpers.put_provider!("extra", %{default_model: "extra-model"}, default: true)
    assert Map.has_key?(Application.get_env(:pincer, :llm_providers), "extra")
    assert Application.get_env(:pincer, :default_llm_provider) == "extra"
    assert is_map(original)
  end

  test "put_app_env!/2 deletes previously unset keys on exit" do
    key = :llm_helpers_ephemeral_test_key
    Application.delete_env(:pincer, key)

    LLMHelpers.put_app_env!(key, :temporary)
    assert Application.get_env(:pincer, key) == :temporary
  end

  test "put_system_env!/2 sets and restores OS env vars" do
    var = "PINCER_TEST_LLM_HELPER_VAR_#{System.unique_integer([:positive])}"
    assert System.get_env(var) == nil

    LLMHelpers.put_system_env!(var, "secret-123")
    assert System.get_env(var) == "secret-123"
  end
end
