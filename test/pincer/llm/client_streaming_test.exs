defmodule Pincer.LLM.ClientStreamingTest do
  use ExUnit.Case

  alias Pincer.LLM.Client

  defmodule MockStreamingAdapter do
    use Pincer.Test.Support.LLMProviderDefaults

    @impl true
    def chat_completion(_messages, _model, _config, _tools) do
      {:ok, %{"role" => "assistant", "content" => "Not streaming"}}
    end

    @impl true
    def stream_completion(_messages, _model, _config, _tools) do
      # Simulate a stream of tokens
      stream =
        Stream.map(["Hello", " world", "!"], fn token ->
          %{"choices" => [%{"delta" => %{"content" => token}}]}
        end)

      {:ok, stream}
    end
  end

  setup do
    Application.put_env(:pincer, :llm_providers, %{
      "stream_provider" => %{
        adapter: MockStreamingAdapter,
        env_key: "STREAM_API_KEY",
        default_model: "stream-model"
      }
    })

    Application.put_env(:pincer, :default_llm_provider, "stream_provider")
    System.put_env("STREAM_API_KEY", "stream_key_123")

    on_exit(fn ->
      Application.delete_env(:pincer, :llm_providers)
      Application.delete_env(:pincer, :default_llm_provider)
    end)

    :ok
  end

  describe "stream_completion/2" do
    test "returns an enumerable stream of chunks" do
      messages = [%{"role" => "user", "content" => "Hi"}]

      assert {:ok, stream} = Client.stream_completion(messages)

      chunks = Enum.to_list(stream)
      assert length(chunks) == 3

      assert List.first(chunks)["choices"] |> List.first() |> get_in(["delta", "content"]) ==
               "Hello"
    end
  end
end
