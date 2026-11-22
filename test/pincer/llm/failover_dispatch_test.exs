defmodule Pincer.LLM.FailoverDispatchTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.LLM.FailoverPolicy
  alias Pincer.LLM.FailoverDispatch

  @registry %{
    "primary" => %{adapter: __MODULE__, default_model: "m"},
    "backup" => %{adapter: __MODULE__, default_model: "m"}
  }

  @transient {:http_error, 503, "upstream unavailable"}

  defp no_retry do
    fn _provider, _model, _state -> flunk("failover retry must not run") end
  end

  defp state do
    FailoverPolicy.initial_state(provider: "primary", model: "m", registry: @registry)
  end

  defp opts(retry, telemetry \\ fn _reason, _meta -> :ok end, status \\ fn _p -> :ok end) do
    [retry: retry, telemetry: telemetry, status: status]
  end

  test "fails fast without retrying when the reason is not recoverable" do
    assert {:error, {:missing_credentials, "KEY"}} =
             FailoverDispatch.handle(
               :chat_completion,
               {:missing_credentials, "KEY"},
               nil,
               opts(no_retry())
             )
  end

  test "reports a fail-fast decision through telemetry" do
    parent = self()

    assert {:error, {:missing_credentials, "KEY"}} =
             FailoverDispatch.handle(
               :stream_completion,
               {:missing_credentials, "KEY"},
               nil,
               opts(no_retry(), fn reason, meta -> send(parent, {:telemetry, reason, meta}) end)
             )

    assert_received {:telemetry, {:missing_credentials, "KEY"},
                     %{action: :stream_completion, failover_action: :fail_fast}}
  end

  test "reports a stopped failover with the attempt count" do
    parent = self()

    ExUnit.CaptureLog.capture_log(fn ->
      assert {:error, :transient} =
               FailoverDispatch.handle(
                 :chat_completion,
                 :transient,
                 state(),
                 opts(
                   no_retry(),
                   fn reason, meta -> send(parent, {:telemetry, reason, meta}) end,
                   fn payload -> send(parent, {:status, payload}) end
                 )
               )
    end)

    assert_received {:telemetry, :transient,
                     %{action: :chat_completion, failover_action: :stop, failover_attempts: count}}

    assert count > 0

    assert_received {:status,
                     %{
                       kind: :failover,
                       action: :chat_completion,
                       failover_action: :stop,
                       provider: "primary"
                     }}
  end

  test "re-enters the caller with the route the policy chooses" do
    parent = self()

    retry = fn provider, model, next_state ->
      send(parent, {:retried, provider, model, next_state})
      {:error, :after_failover}
    end

    ExUnit.CaptureLog.capture_log(fn ->
      assert {:error, :after_failover} =
               FailoverDispatch.handle(
                 :stream_completion,
                 @transient,
                 state(),
                 opts(retry, fn _r, _m -> :ok end, fn _p -> :ok end)
               )
    end)

    assert_received {:retried, provider, model, next_state}
    assert is_binary(provider)
    assert is_binary(model)
    assert is_map(next_state)
  end

  test "asks the policy for the next action using the state it was given" do
    parent = self()

    retry = fn provider, model, next_state ->
      send(parent, {:retried, provider, model, next_state})
      {:ok, :reached}
    end

    ExUnit.CaptureLog.capture_log(fn ->
      FailoverDispatch.handle(
        :chat_completion,
        @transient,
        state(),
        opts(retry, fn _r, _m -> :ok end, fn _p -> :ok end)
      )
    end)

    assert_received {:retried, _provider, _model, next_state}
    assert MapSet.size(next_state.attempted_routes) >= 1
  end
end
