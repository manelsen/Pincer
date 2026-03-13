defmodule Pincer.Core.ExecutorToolFallbackTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.Executor

  defmodule ToolRegistryStub do
    @behaviour Pincer.Ports.ToolRegistry

    @impl true
    def list_tools do
      [%{"name" => "my_tool", "description" => "A mock tool"}]
    end

    @impl true
    def execute_tool(_name, _args, _context) do
      {:ok, "unused"}
    end
  end

  defmodule NoToolSupportLLM do
    @behaviour Pincer.Ports.LLM

    @impl true
    def chat_completion(_messages, opts) do
      send(self(), {:chat_completion_opts, opts})
      {:ok, %{"role" => "assistant", "content" => "I cannot call tools on this model."}, nil}
    end

    @impl true
    def stream_completion(_messages, opts) do
      send(self(), {:stream_completion_opts, opts})

      {:error,
       {:http_error, 400,
        ~s({"error":{"message":"`tool calling` is not supported with this model"}})}}
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

  test "retries fallback chat completion without tools when provider rejects tool calling" do
    history = [%{"role" => "user", "content" => "Run tool if you can"}]

    Executor.run(self(), "tool_fallback_no_tools_session", history,
      tool_registry: ToolRegistryStub,
      llm_client: NoToolSupportLLM
    )

    assert_receive {:stream_completion_opts, stream_opts}, 1000
    assert [%{"name" => "my_tool"}] = Keyword.get(stream_opts, :tools)

    assert_receive {:chat_completion_opts, chat_opts}, 1000
    assert Keyword.get(chat_opts, :tools) in [nil, []]

    assert_receive {:executor_finished, _, "I cannot call tools on this model.", _usage}, 1000
    refute_receive {:executor_failed, _}
  end
end
