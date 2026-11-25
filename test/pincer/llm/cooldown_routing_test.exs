defmodule Pincer.LLM.CooldownRoutingTest do
  use ExUnit.Case, async: false

  alias Pincer.Core.LLM.CooldownStore
  alias Pincer.LLM.CooldownRouting

  @registry %{
    "primary" => %{adapter: __MODULE__, default_model: "m"},
    "backup" => %{adapter: __MODULE__, default_model: "m"}
  }

  setup do
    CooldownStore.clear_provider("primary")

    previous = Application.get_env(:pincer, :llm_providers)
    Application.put_env(:pincer, :llm_providers, @registry)

    on_exit(fn ->
      CooldownStore.clear_provider("primary")

      if previous do
        Application.put_env(:pincer, :llm_providers, previous)
      else
        Application.delete_env(:pincer, :llm_providers)
      end
    end)

    :ok
  end

  describe "route_around_cooldown/3" do
    test "returns the provider untouched when it is explicitly requested" do
      assert CooldownRouting.route_around_cooldown("primary", @registry, true) == "primary"
    end

    test "returns nil and empty ids untouched" do
      assert CooldownRouting.route_around_cooldown(nil, @registry, false) == nil
      assert CooldownRouting.route_around_cooldown("", @registry, false) == ""
    end

    test "returns the mock provider untouched" do
      assert CooldownRouting.route_around_cooldown("mock", @registry, false) == "mock"
    end

    test "returns the provider untouched when no registry is given" do
      assert CooldownRouting.route_around_cooldown("primary", :not_a_map, false) == "primary"
    end

    test "returns the provider untouched when it is not cooling down" do
      assert CooldownRouting.route_around_cooldown("primary", @registry, false) == "primary"
    end
  end

  describe "clear_provider_cooldown/1" do
    test "is a no-op for non-map state" do
      assert CooldownRouting.clear_provider_cooldown(:none) == :ok
      assert CooldownRouting.clear_provider_cooldown(nil) == :ok
    end

    test "is a no-op when the state carries no provider" do
      assert CooldownRouting.clear_provider_cooldown(%{}) == :ok
      assert CooldownRouting.clear_provider_cooldown(%{current_provider: nil}) == :ok
    end
  end

  describe "provider_registry/0" do
    test "returns the configured provider registry" do
      assert CooldownRouting.provider_registry() == @registry
    end

    test "returns an empty map when the registry is not a map" do
      Application.put_env(:pincer, :llm_providers, :bogus)

      assert CooldownRouting.provider_registry() == %{}
    end
  end

  describe "reason_label/1" do
    test "labels http errors with their status" do
      assert CooldownRouting.reason_label({:http_error, 503, "body"}) == "HTTP 503"
      assert CooldownRouting.reason_label({:http_error, 429, "body", %{}}) == "HTTP 429"
    end

    test "labels timeouts and transport errors" do
      assert CooldownRouting.reason_label({:timeout, :deadline}) == "internal timeout"

      assert CooldownRouting.reason_label({:transport_error, :econnrefused}) ==
               "transport :econnrefused"

      assert CooldownRouting.reason_label(%Req.TransportError{reason: :econnrefused}) ==
               "transport :econnrefused"
    end

    test "falls back to inspect for anything else" do
      assert CooldownRouting.reason_label(:unexpected) == ":unexpected"
    end
  end
end
