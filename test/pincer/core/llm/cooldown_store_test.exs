defmodule Pincer.Core.LLM.CooldownStoreTest do
  use ExUnit.Case, async: false

  alias Pincer.Core.LLM.CooldownStore

  setup do
    original = Application.get_env(:pincer, :llm_cooldown)

    Application.put_env(:pincer, :llm_cooldown,
      durations_ms: %{
        http_429: 200,
        http_5xx: 150,
        transport_timeout: 100,
        process_timeout: 100
      }
    )

    CooldownStore.reset()

    on_exit(fn ->
      CooldownStore.reset()

      if original do
        Application.put_env(:pincer, :llm_cooldown, original)
      else
        Application.delete_env(:pincer, :llm_cooldown)
      end
    end)

    :ok
  end

  test "cooldown_provider/2 marks provider in cooldown for transient class" do
    refute CooldownStore.cooling_down?("p1")

    assert :ok = CooldownStore.cooldown_provider("p1", {:http_error, 429, "rate"})
    assert CooldownStore.cooling_down?("p1")
  end

  test "available_providers/1 filters providers in cooldown" do
    CooldownStore.cooldown_provider("p1", {:http_error, 503, "upstream"})

    assert CooldownStore.available_providers(["p1", "p2", "p3"]) == ["p2", "p3"]
  end

  test "clear_provider/1 removes cooldown entry" do
    CooldownStore.cooldown_provider("p1", {:http_error, 429, "rate"})
    assert CooldownStore.cooling_down?("p1")

    assert :ok = CooldownStore.clear_provider("p1")
    refute CooldownStore.cooling_down?("p1")
  end
end
