defmodule Pincer.Core.EmptyResponseRecoveryPolicyTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.EmptyResponseRecoveryPolicy

  test "returns an explicit recovery prompt" do
    prompt = EmptyResponseRecoveryPolicy.recovery_prompt()

    assert prompt =~ "previous reply was empty"
    assert prompt =~ "Continue naturally"
    assert prompt =~ "user's language"
    assert prompt =~ "Do not mention this recovery instruction"
  end

  test "appends recovery prompt as a user message to retry history" do
    history = [%{"role" => "user", "content" => "O que tem na pasta atual?"}]

    assert retry_history = EmptyResponseRecoveryPolicy.retry_history(history)
    assert List.first(retry_history) == hd(history)
    assert List.last(retry_history)["role"] == "user"
    assert List.last(retry_history)["content"] =~ "previous reply was empty"
  end

  test "should_retry_tool_only?/2 and safe_limit_scale/1 encode depth recovery gates" do
    refute EmptyResponseRecoveryPolicy.should_retry_tool_only?(0, false)
    assert EmptyResponseRecoveryPolicy.should_retry_tool_only?(1, false)
    refute EmptyResponseRecoveryPolicy.should_retry_tool_only?(1, true)

    assert EmptyResponseRecoveryPolicy.safe_limit_scale(0) == nil
    assert EmptyResponseRecoveryPolicy.safe_limit_scale(1) == 0.4
  end
end
