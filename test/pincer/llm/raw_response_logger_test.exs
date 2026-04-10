defmodule Pincer.LLM.RawResponseLoggerTest do
  # async: false because we temporarily change the global Logger level to :debug
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Pincer.LLM.RawResponseLogger

  setup do
    # RawResponseLogger uses Logger.debug; the default level is :info so we must
    # temporarily lower it to capture these messages.
    original_level = Logger.level()
    Logger.configure(level: :debug)

    on_exit(fn ->
      Logger.configure(level: original_level)
    end)

    :ok
  end

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
