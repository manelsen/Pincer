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
end
