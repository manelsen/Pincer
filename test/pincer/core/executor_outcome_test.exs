defmodule Pincer.Core.ExecutorOutcomeTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.Executor
  alias PincerPorts.Structs.Usage

  defmodule OkWithUsageLLM do
    @behaviour Pincer.Ports.LLM

    @impl true
    def chat_completion(_messages, _opts), do: {:error, :not_implemented}

    @impl true
    def stream_completion(_messages, _opts) do
      {:ok, [%{"choices" => [%{"delta" => %{"content" => "Resposta ok"}}]}],
       %{"prompt_tokens" => 11, "completion_tokens" => 7}}
    end

    @impl true
    def list_providers, do: []
    @impl true
    def list_models(_id), do: []
    @impl true
    def transcribe_audio(_path, _opts), do: {:error, :not_implemented}
    @impl true
    def generate_embedding(_text, _opts), do: {:error, :not_implemented}
    @impl true
    def provider_config(_id), do: nil
  end

  defmodule FailingFallbackLLM do
    @behaviour Pincer.Ports.LLM

    @impl true
    def chat_completion(_messages, _opts), do: {:error, :backend_down}

    @impl true
    def stream_completion(_messages, _opts), do: {:error, :stream_down}

    @impl true
    def list_providers, do: []
    @impl true
    def list_models(_id), do: []
    @impl true
    def transcribe_audio(_path, _opts), do: {:error, :not_implemented}
    @impl true
    def generate_embedding(_text, _opts), do: {:error, :not_implemented}
    @impl true
    def provider_config(_id), do: nil
  end

  test "run/4 returns {:ok, history, content, %Usage{}} directly and keeps process dict clean" do
    history = [%{"role" => "user", "content" => "oi"}]

    assert {:ok, final_history, "Resposta ok",
            %Usage{prompt_tokens: 11, completion_tokens: 7, total_tokens: 18}} =
             Executor.run(self(), "outcome_ok_session", history,
               llm_client: OkWithUsageLLM,
               trace_events?: true
             )

    assert List.last(final_history)["content"] == "Resposta ok"

    assert_receive {:executor_finished, ^final_history, "Resposta ok",
                    %Usage{prompt_tokens: 11, completion_tokens: 7, total_tokens: 18}},
                   1_000

    refute_received {:executor_finished, _, _, _}
    assert Process.get(:workspace_path) == nil
    assert Process.get(:executor_deps) == nil
    assert Process.get(:executor_run_opts) == nil
    assert Process.get(:executor_trace) == nil
    assert Process.get(:executor_trace_session_pid) == nil
    assert Process.get(:consecutive_errors) == nil
  end

  test "run/4 emits {:executor_failed, reason} exactly once on depth, loop, and fallback errors" do
    history = [%{"role" => "user", "content" => "oi"}]

    assert {:error, {:depth_exceeded, 0}} =
             Executor.run(self(), "outcome_depth_session", history,
               llm_client: OkWithUsageLLM,
               max_depth: -1
             )

    assert_received {:executor_failed, {:depth_exceeded, 0}}
    refute_received {:executor_failed, _}

    call_msg = %{
      "role" => "assistant",
      "content" => nil,
      "tool_calls" => [
        %{"id" => "c1", "function" => %{"name" => "safe_shell", "arguments" => "{}"}}
      ]
    }

    assert {:error, :tool_loop} =
             Executor.run(self(), "outcome_loop_session", [call_msg, call_msg, call_msg],
               llm_client: OkWithUsageLLM
             )

    assert_received {:executor_failed, :tool_loop}
    refute_received {:executor_failed, _}

    assert {:error, :backend_down} =
             Executor.run(self(), "outcome_fallback_session", history,
               llm_client: FailingFallbackLLM
             )

    assert_received {:executor_failed, :backend_down}
    refute_received {:executor_failed, _}
  end

  test "notify?: false suppresses mailbox messages while returning outcome" do
    history = [%{"role" => "user", "content" => "oi"}]

    assert {:ok, _hist, "Resposta ok", %Usage{}} =
             Executor.run(self(), "outcome_silent_ok", history,
               llm_client: OkWithUsageLLM,
               notify?: false
             )

    refute_received {:executor_finished, _, _, _}
    refute_received {:executor_finished, _, _, _, _}

    assert {:error, :backend_down} =
             Executor.run(self(), "outcome_silent_err", history,
               llm_client: FailingFallbackLLM,
               notify?: false
             )

    refute_received {:executor_failed, _}
    refute_received {:executor_failed, _, _}
  end

  test "ref option tags executor_finished and executor_failed notifications" do
    history = [%{"role" => "user", "content" => "oi"}]
    ok_ref = make_ref()
    err_ref = make_ref()

    assert {:ok, _hist, "Resposta ok", %Usage{}} =
             Executor.run(self(), "outcome_ref_ok", history,
               llm_client: OkWithUsageLLM,
               ref: ok_ref
             )

    assert_received {:executor_finished, ^ok_ref, _hist, "Resposta ok", %Usage{}}

    assert {:error, :backend_down} =
             Executor.run(self(), "outcome_ref_err", history,
               llm_client: FailingFallbackLLM,
               ref: err_ref
             )

    assert_received {:executor_failed, ^err_ref, :backend_down}
  end
end
