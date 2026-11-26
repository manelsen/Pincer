defmodule Pincer.LLM.RawResponseLoggerTest do
  # async: false because we temporarily change the global Logger level and app env
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias PincerPorts.LLM.RawResponseLogger

  setup do
    original_level = Logger.level()
    original_flag = Application.get_env(:pincer, :log_raw_llm_payloads, :__unset__)
    original_env = System.get_env("PINCER_LOG_RAW_LLM")

    Logger.configure(level: :debug)

    on_exit(fn ->
      Logger.configure(level: original_level)

      case original_flag do
        :__unset__ -> Application.delete_env(:pincer, :log_raw_llm_payloads)
        val -> Application.put_env(:pincer, :log_raw_llm_payloads, val)
      end

      case original_env do
        nil -> System.delete_env("PINCER_LOG_RAW_LLM")
        val -> System.put_env("PINCER_LOG_RAW_LLM", val)
      end
    end)

    :ok
  end

  test "does not log raw payloads by default even when Logger level is :debug" do
    Application.delete_env(:pincer, :log_raw_llm_payloads)
    System.delete_env("PINCER_LOG_RAW_LLM")

    log =
      capture_log(fn ->
        RawResponseLogger.log_response("openai_compat", 200, %{
          "choices" => [%{"message" => %{"content" => "secret response"}}],
          "api_key" => "sk-secret-value"
        })

        RawResponseLogger.log_payload("ollama", "jsonl", ~s({"token":"super-secret"}))
      end)

    assert log == ""
  end

  test "logs bounded and redacted response body when explicitly opted in" do
    Application.put_env(:pincer, :log_raw_llm_payloads, true)

    oversized_text = String.duplicate("a", 12_000)

    log =
      capture_log(fn ->
        RawResponseLogger.log_response("openai_compat", 200, %{
          "Authorization" => "Bearer synthetic-bearer-token-999",
          "nested" => %{
            "api_key" => "sk-synthetic-secret-123",
            "access_token" => "tok-synthetic-456"
          },
          "choices" => [%{"message" => %{"content" => oversized_text}}]
        })
      end)

    assert log =~ "[LLM RAW][openai_compat] status=200 body="
    assert log =~ "[REDACTED]"
    refute log =~ "synthetic-bearer-token-999"
    refute log =~ "sk-synthetic-secret-123"
    refute log =~ "tok-synthetic-456"
    assert byte_size(log) < 5_000
    refute log =~ String.duplicate("a", 3_000)

    wide_payload = Map.new(1..45, fn i -> {"field_#{i}", String.duplicate("z", 120)} end)

    wide_log =
      capture_log(fn ->
        RawResponseLogger.log_response("openai_compat", 200, wide_payload)
      end)

    assert byte_size(wide_log) < 5_000
    assert wide_log =~ "...[truncated]"
  end

  test "logs bounded raw payloads via PINCER_LOG_RAW_LLM env opt-in and redacts bearer strings" do
    Application.delete_env(:pincer, :log_raw_llm_payloads)
    System.put_env("PINCER_LOG_RAW_LLM", "true")

    log =
      capture_log(fn ->
        RawResponseLogger.log_payload(
          "ollama",
          "jsonl",
          ~s({"Authorization":"Bearer raw-secret-token","message":{"content":"oi"}})
        )
      end)

    assert log =~ "[LLM RAW][ollama][jsonl]"
    refute log =~ "raw-secret-token"
    assert log =~ "oi"
  end
end
