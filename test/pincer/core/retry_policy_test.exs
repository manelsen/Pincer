defmodule Pincer.Core.RetryPolicyTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.RetryPolicy

  describe "retryable?/1" do
    test "returns true for transient HTTP and transport reasons" do
      assert RetryPolicy.retryable?({:http_error, 408, "timeout"})
      assert RetryPolicy.retryable?({:http_error, 429, "rate"})
      assert RetryPolicy.retryable?({:http_error, 503, "upstream"})
      assert RetryPolicy.retryable?(%Req.TransportError{reason: :timeout})
      assert RetryPolicy.retryable?(%Req.TransportError{reason: :econnrefused})
      assert RetryPolicy.retryable?({:timeout, :gen_server_call})
    end

    test "returns false for non-retryable reasons" do
      refute RetryPolicy.retryable?({:http_error, 401, "unauthorized"})
      refute RetryPolicy.retryable?(:tool_loop)
      refute RetryPolicy.retryable?(:invalid)
    end
  end

  describe "transient?/1" do
    test "returns true for transient operational classes" do
      assert RetryPolicy.transient?({:http_error, 503, "upstream"})
      assert RetryPolicy.transient?(%Req.TransportError{reason: :timeout})
      assert RetryPolicy.transient?({:invalid_stream_response, %{}})
    end

    test "returns false for terminal classes" do
      refute RetryPolicy.transient?({:http_error, 401, "unauthorized"})
      refute RetryPolicy.transient?(:tool_loop)
      refute RetryPolicy.transient?(:anything_else)
    end
  end

  describe "fail_fast?/1" do
    test "returns true for terminal classes that should not trigger failover noise" do
      assert RetryPolicy.fail_fast?({:missing_credentials, "OPENAI_API_KEY"})
      assert RetryPolicy.fail_fast?(:all_profiles_cooling_down)
      assert RetryPolicy.fail_fast?({:provider_error, 400, "Provider returned error"})
      assert RetryPolicy.fail_fast?(:non_json_response)
      assert RetryPolicy.fail_fast?(:empty_response)
      assert RetryPolicy.fail_fast?({:http_error, 404, "missing"})
    end

    test "returns false for transient classes" do
      refute RetryPolicy.fail_fast?({:http_error, 503, "upstream"})
      refute RetryPolicy.fail_fast?(%Req.TransportError{reason: :timeout})
    end
  end

  describe "retry_after_ms/3" do
    test "reads retry_after metadata and clamps to remaining deadline" do
      reason = {:http_error, 429, "rate", %{retry_after_ms: 5_000}}
      assert RetryPolicy.retry_after_ms(reason, 1_600, 2_000) == 400
    end

    test "supports retry_after in seconds string" do
      reason = {:http_error, 503, "busy", %{retry_after: "2"}}
      assert RetryPolicy.retry_after_ms(reason, 0, 5_000) == 2_000
    end

    test "returns nil for unsupported reason shape" do
      assert RetryPolicy.retry_after_ms({:http_error, 401, "unauthorized"}, 0, 5_000) == nil
      assert RetryPolicy.retry_after_ms(:invalid, 0, 5_000) == nil
    end
  end

  describe "parse_retry_after/2" do
    test "parses HTTP-date into milliseconds delta" do
      now_ms = 1_700_000_000_000
      retry_after = "Tue, 14 Nov 2023 22:13:21 GMT"

      assert RetryPolicy.parse_retry_after(retry_after, now_ms) == 1_000
    end
  end
end
