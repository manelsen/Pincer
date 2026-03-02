defmodule Pincer.Core.LLM.FailoverPolicyTest do
  use ExUnit.Case, async: false

  alias Pincer.Core.LLM.CooldownStore
  alias Pincer.Core.LLM.FailoverPolicy

  @registry %{
    "p1" => %{
      default_model: "m1",
      models: ["m1", "m2"]
    },
    "p2" => %{
      default_model: "x1",
      models: ["x1"]
    }
  }

  setup do
    CooldownStore.reset()

    on_exit(fn ->
      CooldownStore.reset()
    end)

    :ok
  end

  test "applies retry_same while below local threshold" do
    state0 =
      FailoverPolicy.initial_state(
        provider: "p1",
        model: "m1",
        registry: @registry,
        retry_same_limit: 1
      )

    reason = {:http_error, 503, "upstream"}

    {action1, state1} = FailoverPolicy.next_action(reason, state0)
    assert action1 == :retry_same
    summary = FailoverPolicy.summarize_attempts(state1)
    assert [%{action: :retry_same}] = summary.attempts
  end

  test "walks deterministic chain: fallback_model -> fallback_provider -> stop" do
    state0 =
      FailoverPolicy.initial_state(
        provider: "p1",
        model: "m1",
        registry: @registry,
        retry_same_limit: 0
      )

    reason = {:http_error, 503, "upstream"}

    {action1, state1} = FailoverPolicy.next_action(reason, state0)
    assert action1 == {:fallback_model, "p1", "m2"}

    {action2, state2} = FailoverPolicy.next_action(reason, state1)
    assert action2 == {:fallback_provider, "p2", "x1"}

    {action3, state3} = FailoverPolicy.next_action(reason, state2)
    assert action3 == :stop

    summary = FailoverPolicy.summarize_attempts(state3)
    assert is_list(summary.attempts)
    assert length(summary.attempts) == 3
    assert summary.terminal_reason == reason
  end

  test "stops immediately for terminal class" do
    state =
      FailoverPolicy.initial_state(
        provider: "p1",
        model: "m1",
        registry: @registry,
        retry_same_limit: 2
      )

    reason = {:http_error, 401, "unauthorized"}

    {action, state2} = FailoverPolicy.next_action(reason, state)
    assert action == :stop

    summary = FailoverPolicy.summarize_attempts(state2)
    assert summary.terminal_reason == reason
    assert [%{action: :stop, class: :http_401}] = summary.attempts
  end

  test "skips provider candidates that are cooling down" do
    CooldownStore.cooldown_provider("p2", {:http_error, 429, "rate"})

    state0 =
      FailoverPolicy.initial_state(
        provider: "p1",
        model: "m1",
        registry: @registry,
        retry_same_limit: 0
      )

    reason = {:http_error, 503, "upstream"}

    {action1, state1} = FailoverPolicy.next_action(reason, state0)
    assert action1 == {:fallback_model, "p1", "m2"}

    {action2, _state2} = FailoverPolicy.next_action(reason, state1)
    assert action2 == :stop
  end
end
