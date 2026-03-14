defmodule Pincer.LLM.RawResponseLoggerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Pincer.LLM.RawResponseLogger

  test "logs full response body with provider and status" do
    log =
      capture_log(fn ->
        RawResponseLogger.log_response("openai_compat", 200, %{
          "choices" => [%{"message" => %{"content" => "oi"}}]
        })
      end)

    assert log =~ "[LLM RAW][openai_compat] status=200 body="
    assert log =~ "\"choices\" =>"
    assert log =~ "\"content\" => \"oi\""
  end

  test "logs labeled raw payloads" do
    log =
      capture_log(fn ->
        RawResponseLogger.log_payload("ollama", "jsonl", ~s({"message":{"content":"oi"}}))
      end)

    assert log =~ "[LLM RAW][ollama][jsonl]"
    assert log =~ "\\\"message\\\":{"
    assert log =~ "\\\"content\\\":\\\"oi\\\""
  end
end
