defmodule Pincer.Core.EmptyResponseRecoveryPolicyTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.EmptyResponseRecoveryPolicy

  test "allows lightweight retry for greetings and smalltalk" do
    assert EmptyResponseRecoveryPolicy.allow_chat_retry?([
             %{"role" => "user", "content" => "Oi"}
           ])

    assert EmptyResponseRecoveryPolicy.allow_chat_retry?([
             %{"role" => "user", "content" => "Tudo bom contigo?"}
           ])
  end

  test "denies lightweight retry for factual or workspace questions" do
    refute EmptyResponseRecoveryPolicy.allow_chat_retry?([
             %{"role" => "user", "content" => "O que tem na pasta atual?"}
           ])

    refute EmptyResponseRecoveryPolicy.allow_chat_retry?([
             %{"role" => "user", "content" => "O que tem em https://www.cade.com.br?"}
           ])
  end
end
