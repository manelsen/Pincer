defmodule Pincer.Core.ExecutorStreamingTest do
  use ExUnit.Case

  alias Pincer.Core.Executor

  defmodule MockStreamProvider do
    @behaviour Pincer.LLM.Provider

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
    assert_receive {:executor_finished, _history, "Hello world!"}, 2000
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
