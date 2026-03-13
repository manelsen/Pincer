defmodule Pincer.Core.ExecutorContextOverflowTest do
  use ExUnit.Case

  alias Pincer.Core.Executor

  defmodule OverflowRecoveringLLM do
    @behaviour Pincer.Ports.LLM

    @impl true
    def list_providers, do: []

    @impl true
    def list_models(_provider_id), do: []

    @impl true
    def transcribe_audio(_file_path, _opts), do: {:error, :not_implemented}

    @impl true
    def provider_config("overflow_probe"), do: %{context_window: 10_000}

    @impl true
    def provider_config(_provider_id), do: nil

    @impl true
    def stream_completion(messages, _opts) do
      send(self(), {:stream_messages, messages})
      {:error, {:http_error, 400, "maximum context length exceeded"}}
    end

    @impl true
    def chat_completion(messages, opts) do
      send(self(), {:chat_messages, messages, opts})

      total_bytes =
        messages
        |> Enum.map(&Map.get(&1, "content", ""))
        |> Enum.join()
        |> byte_size()

      cond do
        Keyword.has_key?(opts, :tools) ->
          flunk("context overflow fallback should drop tools")

        total_bytes >= 3_500 ->
          flunk("context overflow fallback should reduce prompt size")

        true ->
          {:ok, %{"role" => "assistant", "content" => "Recovered after pruning"}, nil}
      end
    end
  end

  defmodule ToolRegistryStub do
    @behaviour Pincer.Ports.ToolRegistry

    @impl true
    def list_tools do
      [%{"name" => "my_tool", "description" => "A mock tool"}]
    end

    @impl true
    def execute_tool("my_tool", %{"arg" => "val"}, _context) do
      {:ok, "Tool Result"}
    end
  end

  test "executor retries context overflow with aggressively pruned history and no tools" do
    payload = String.duplicate("token ", 480)

    history =
      [%{"role" => "system", "content" => "You are a bot"}] ++
        Enum.map(1..10, fn idx ->
          %{"role" => "user", "content" => "msg-#{idx} " <> payload}
        end)

    Executor.run(self(), "test_context_overflow_recovery_session", history,
      llm_client: OverflowRecoveringLLM,
      tool_registry: ToolRegistryStub,
      model_override: %{provider: "overflow_probe", model: "probe-model"}
    )

    assert_receive {:stream_messages, stream_messages}, 2_000

    stream_payload =
      stream_messages
      |> Enum.map(&Map.get(&1, "content", ""))
      |> Enum.join()
      |> byte_size()

    assert stream_payload > 3_500

    assert_receive {:chat_messages, chat_messages, chat_opts}, 2_000
    refute Keyword.has_key?(chat_opts, :tools)

    retained_messages =
      chat_messages
      |> Enum.map(&Map.get(&1, "content", ""))
      |> Enum.filter(&String.starts_with?(&1, "msg-"))

    assert retained_messages != []
    assert Enum.at(retained_messages, -1) =~ "msg-10"
    refute Enum.any?(retained_messages, &String.starts_with?(&1, "msg-1 "))

    assert_receive {:executor_finished, _history, "Recovered after pruning", _usage}, 2_000
  end
end
