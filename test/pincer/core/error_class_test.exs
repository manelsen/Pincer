defmodule Pincer.Core.ErrorClassTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.ErrorClass

  describe "classify/1" do
    test "classifies HTTP classes" do
      assert ErrorClass.classify({:http_error, 401, "x"}) == :http_401
      assert ErrorClass.classify({:http_error, 403, "x"}) == :http_403
      assert ErrorClass.classify({:http_error, 404, "x"}) == :http_404
      assert ErrorClass.classify({:http_error, 429, "x"}) == :http_429
      assert ErrorClass.classify({:http_error, 503, "x"}) == :http_5xx
    end

    test "classifies context overflow from HTTP 400 body" do
      reason =
        {:http_error, 400,
         "max_tokens too large for maximum context length with input tokens overflow"}

      assert ErrorClass.classify(reason) == :context_overflow
    end

    test "classifies transport and process failures" do
      assert ErrorClass.classify(%Req.TransportError{reason: :timeout}) == :transport_timeout
      assert ErrorClass.classify(%Req.TransportError{reason: :econnrefused}) == :transport_connect
      assert ErrorClass.classify(%Req.TransportError{reason: :nxdomain}) == :transport_dns
      assert ErrorClass.classify({:timeout, :gen_server_call}) == :process_timeout
      assert ErrorClass.classify({:retry_timeout, :x}) == :retry_timeout
    end

    test "classifies internal and domain-specific errors" do
      assert ErrorClass.classify(:tool_loop) == :tool_loop
      assert ErrorClass.classify({:invalid_stream_response, :bad}) == :stream_payload

      assert ErrorClass.classify(%Protocol.UndefinedError{
               protocol: Enumerable,
               value: %{},
               description: ""
             }) == :stream_payload

      assert ErrorClass.classify(%Exqlite.Error{message: "no such table: events"}) == :db_schema
    end

    test "falls back to unknown class" do
      assert ErrorClass.classify(:something_else) == :unknown
    end
  end
end
