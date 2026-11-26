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

    assert Enum.map(summary.attempts, & &1.action) == [
             {:fallback_model, "p1", "m2"},
             {:fallback_provider, "p2", "x1"},
             :stop
           ]
  end

  test "preserves exact chronological attempts order across retries and fallbacks" do
    state0 =
      FailoverPolicy.initial_state(
        provider: "p1",
        model: "m1",
        registry: @registry,
        retry_same_limit: 1
      )

    r1 = {:http_error, 503, "step1"}
    r2 = {:http_error, 429, "step2"}
    r3 = {:http_error, 500, "step3"}
    r4 = {:http_error, 502, "step4"}
    r5 = {:http_error, 504, "step5"}
    r6 = {:http_error, 503, "step6"}

    {a1, state1} = FailoverPolicy.next_action(r1, state0)
    {a2, state2} = FailoverPolicy.next_action(r2, state1)
    {a3, state3} = FailoverPolicy.next_action(r3, state2)
    {a4, state4} = FailoverPolicy.next_action(r4, state3)
    {a5, state5} = FailoverPolicy.next_action(r5, state4)
    {a6, state6} = FailoverPolicy.next_action(r6, state5)

    assert [a1, a2, a3, a4, a5, a6] == [
             :retry_same,
             {:fallback_model, "p1", "m2"},
             :retry_same,
             {:fallback_provider, "p2", "x1"},
             :retry_same,
             :stop
           ]

    summary = FailoverPolicy.summarize_attempts(state6)

    assert Enum.map(summary.attempts, &{&1.action, &1.reason}) == [
             {:retry_same, r1},
             {{:fallback_model, "p1", "m2"}, r2},
             {:retry_same, r3},
             {{:fallback_provider, "p2", "x1"}, r4},
             {:retry_same, r5},
             {:stop, r6}
           ]
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
