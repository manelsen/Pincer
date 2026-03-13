defmodule Pincer.Core.ExecutorStreamingTest do
  use ExUnit.Case

  alias Pincer.Core.Executor
  alias Pincer.Utils.Tokenizer

  defmodule MockStreamProvider do
    use Pincer.Test.Support.LLMProviderDefaults

    @impl true
    def chat_completion(_messages, _model, _config, _tools) do
      {:ok, %{"role" => "assistant", "content" => "Not streaming"}}
    end

    @impl true
    def stream_completion(_messages, _model, _config, _tools) do
      # Simulate a stream of chunks
      stream =
        Stream.map(["Hello", " world", "!"], fn token ->
          %{"choices" => [%{"delta" => %{"content" => token}}]}
        end)

      {:ok, stream}
    end
  end

  defmodule MockReasoningStreamProvider do
    @behaviour Pincer.Ports.LLM

    @impl true
    def chat_completion(_messages, _opts) do
      {:ok, %{"role" => "assistant", "content" => "Not streaming"}, nil}
    end

    @impl true
    def stream_completion(_messages, _opts) do
      {:ok,
       [
         %{"choices" => [%{"delta" => %{"reasoning_content" => "chain-of-thought"}}]},
         %{"choices" => [%{"delta" => %{"content" => "Resposta final"}}]}
       ]}
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

  defmodule MockReasoningOnlyAfterToolLLM do
    @behaviour Pincer.Ports.LLM

    @impl true
    def list_providers, do: []

    @impl true
    def list_models(_provider_id), do: []

    @impl true
    def transcribe_audio(_file_path, _opts), do: {:error, :not_implemented}

    @impl true
    def provider_config(_provider_id), do: nil

    @impl true
    def chat_completion(_messages, _opts), do: {:error, :not_implemented}

    @impl true
    def stream_completion(history, _opts) do
      if Enum.any?(history, &(&1["role"] == "tool")) do
        assert List.last(history)["role"] == "system"
        assert List.last(history)["content"] =~ "Ground yourself strictly"

        {:ok,
         [%{"choices" => [%{"delta" => %{"reasoning_content" => "private reasoning only"}}]}]}
      else
        {:ok,
         [
           %{
             "choices" => [
               %{
                 "delta" => %{
                   "tool_calls" => [
                     %{
                       "index" => 0,
                       "id" => "call_1",
                       "function" => %{"name" => "my_tool", "arguments" => "{\"arg\": \"val\"}"}
                     }
                   ]
                 }
               }
             ]
           },
           %{"choices" => [%{"delta" => %{}}]}
         ]}
      end
    end
  end

  defmodule ContextWindowProbeLLM do
    @behaviour Pincer.Ports.LLM

    @impl true
    def chat_completion(_messages, _opts), do: {:error, :not_implemented}

    @impl true
    def stream_completion(messages, _opts) do
      send(self(), {:stream_messages, messages})
      {:ok, [%{"choices" => [%{"delta" => %{"content" => "ok"}}]}]}
    end

    @impl true
    def list_providers, do: []

    @impl true
    def list_models(_provider_id), do: []

    @impl true
    def transcribe_audio(_file_path, _opts), do: {:error, :not_implemented}

    def generate_embedding(_text, _opts), do: {:error, :not_implemented}

    @impl true
    def provider_config("context_probe"), do: %{context_window: 10_000}

    @impl true
    def provider_config(_provider_id), do: nil
  end

  setup do
    Application.ensure_all_started(:pincer)
    old_stream_api_key = System.get_env("STREAM_API_KEY")
    System.put_env("STREAM_API_KEY", "test-stream-key")

    Application.put_env(:pincer, :llm_providers, %{
      "exec_stream" => %{
        adapter: MockStreamProvider,
        env_key: "STREAM_API_KEY",
        default_model: "stream-model"
      }
    })

    Application.put_env(:pincer, :default_llm_provider, "exec_stream")

    on_exit(fn ->
      Application.delete_env(:pincer, :llm_providers)
      Application.delete_env(:pincer, :default_llm_provider)
      restore_env("STREAM_API_KEY", old_stream_api_key)
    end)

    :ok
  end

  test "executor emits {:agent_stream_token, token} messages to session" do
    history = [%{"role" => "system", "content" => "You are a bot"}]

    # Run the executor synchronously in a separate process that we link to
    # or just call it directly since it sends messages to self()
    Executor.run(self(), "test_session", history, [])

    # We expect to receive tokens
    assert_receive {:agent_stream_token, "Hello"}, 2000
    assert_receive {:agent_stream_token, " world"}, 2000
    assert_receive {:agent_stream_token, "!"}, 2000

    # Finally, the finished message
    assert_receive {:executor_finished, _history, "Hello world!", _usage}, 2000
  end

  test "executor does not stream reasoning tokens as user-visible partials" do
    history = [%{"role" => "system", "content" => "You are a bot"}]

    Executor.run(self(), "test_reasoning_stream_session", history,
      llm_client: MockReasoningStreamProvider
    )

    assert_receive {:agent_stream_token, "Resposta final"}, 2000
    refute_receive {:agent_stream_token, "chain-of-thought"}, 200
    assert_receive {:executor_finished, _history, "Resposta final", _usage}, 2000
  end

  test "executor synthesizes non-empty final response when post-tool turn returns only reasoning" do
    history = [%{"role" => "user", "content" => "Run tool"}]

    Executor.run(self(), "test_reasoning_only_after_tool_session", history,
      llm_client: MockReasoningOnlyAfterToolLLM,
      tool_registry: ToolRegistryStub
    )

    assert_receive {:sme_tool_use, "my_tool"}, 2000

    assert_receive {:executor_finished, _history, response, _usage}, 2000
    assert response =~ "Ferramentas utilizadas: my_tool"
    assert response =~ "Tool Result"
  end

  test "executor keeps roughly 45 percent of provider context for recent history" do
    payload = String.duplicate("token ", 480)
    assert Tokenizer.estimate(payload) >= 700
    old_llm_adapter = Application.get_env(:pincer, :llm_adapter)

    history =
      [%{"role" => "system", "content" => "You are a bot"}] ++
        Enum.map(1..10, fn idx ->
          %{"role" => "user", "content" => "msg-#{idx} " <> payload}
        end)

    try do
      Application.put_env(:pincer, :llm_adapter, ContextWindowProbeLLM)

      Executor.run(self(), "test_context_sweet_spot_session", history,
        llm_client: ContextWindowProbeLLM,
        model_override: %{provider: "context_probe", model: "probe-model"}
      )
    after
      if old_llm_adapter do
        Application.put_env(:pincer, :llm_adapter, old_llm_adapter)
      else
        Application.delete_env(:pincer, :llm_adapter)
      end
    end

    assert_receive {:stream_messages, streamed_messages}, 2000

    retained_messages =
      streamed_messages
      |> Enum.map(&Map.get(&1, "content", ""))
      |> Enum.filter(&String.starts_with?(&1, "msg-"))

    assert length(retained_messages) >= 5
    assert Enum.at(retained_messages, 0) =~ "msg-5"
    assert Enum.at(retained_messages, -1) =~ "msg-10"

    assert_receive {:executor_finished, _history, "ok", _usage}, 2000
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
