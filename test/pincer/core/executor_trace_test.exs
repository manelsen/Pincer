defmodule Pincer.Core.ExecutorTraceTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.Executor

  defmodule TraceStreamLLM do
    @behaviour Pincer.Ports.LLM

    @impl true
    def chat_completion(_messages, _opts), do: {:error, :not_implemented}

    @impl true
    def stream_completion(_messages, _opts) do
      {:ok, [%{"choices" => [%{"delta" => %{"content" => "trace ok"}}]}]}
    end

    @impl true
    def list_providers, do: []
    @impl true
    def list_models(_provider_id), do: []
    @impl true
    def transcribe_audio(_file_path, _opts), do: {:error, :not_implemented}
    @impl true
    def provider_config(_provider_id), do: nil
  end

  test "emits trace step events and final trace snapshot when enabled" do
    history = [%{"role" => "user", "content" => "ping"}]

    Executor.run(self(), "trace_events_session", history,
      llm_client: TraceStreamLLM,
      trace_events?: true
    )

    assert_receive {:executor_trace_step, :checkpoint, "turn_started", _}, 1_000
    assert_receive {:executor_trace_step, :memory, "prompt_prepared", _}, 1_000
    assert_receive {:executor_trace_step, :policy, "llm_request_prepared", _}, 1_000
    assert_receive {:executor_trace_step, :llm, "stream_completion_invoked", _}, 1_000
    assert_receive {:executor_trace_step, :checkpoint, "turn_finished", _}, 1_000
    assert_receive {:executor_trace, %{"trace" => trace}}, 1_000
    assert_receive {:executor_finished, _history, "trace ok", _usage}, 1_000

    assert is_binary(trace["trace_id"])
    assert trace["session_id"] == "trace_events_session"
    assert Enum.any?(trace["steps"], &(&1["kind"] == "llm"))
  end
end
