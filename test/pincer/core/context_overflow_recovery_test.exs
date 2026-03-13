defmodule Pincer.Core.ContextOverflowRecoveryTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.ContextOverflowRecovery

  test "builds aggressive fallback plan for context overflow" do
    assert {:retry, plan} =
             ContextOverflowRecovery.plan(
               {:http_error, 400, "maximum context length exceeded"},
               tools_present?: true
             )

    assert plan.drop_tools? == true
    assert plan.safe_limit_scale == 0.15
  end

  test "ignores non-context errors" do
    assert :noop =
             ContextOverflowRecovery.plan(
               {:http_error, 429, "rate limited"},
               tools_present?: true
             )
  end
end
