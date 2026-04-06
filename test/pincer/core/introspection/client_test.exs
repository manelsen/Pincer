defmodule Pincer.Core.Introspection.ClientTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.Introspection.Client

  defmodule LLMStub do
    def chat_completion(_messages, opts) do
      send(self(), {:llm_called, opts})
      {:ok, %{"content" => "reflection result"}, %{"prompt_tokens" => 10}}
    end
  end

  describe "chat_completion/2" do
    test "passes introspection config to LLM client" do
      Application.put_env(:pincer, :introspection, %{
        "provider" => "z_ai",
        "model" => "glm-4.7",
        "max_tokens" => 512,
        "temperature" => 0.7
      })

      messages = [%{"role" => "user", "content" => "reflect"}]
      {:ok, _resp, _usage} = Client.chat_completion(messages, llm_client: LLMStub)

      assert_received {:llm_called, opts}
      assert opts[:provider] == "z_ai"
      assert opts[:model] == "glm-4.7"
      assert opts[:max_tokens] == 512
      assert opts[:temperature] == 0.7
    after
      Application.delete_env(:pincer, :introspection)
    end

    test "falls back when no introspection config" do
      Application.delete_env(:pincer, :introspection)

      messages = [%{"role" => "user", "content" => "reflect"}]
      {:ok, _resp, _usage} = Client.chat_completion(messages, llm_client: LLMStub)

      assert_received {:llm_called, opts}
      refute Keyword.has_key?(opts, :provider)
      refute Keyword.has_key?(opts, :model)
    end

    test "partial config only passes present keys" do
      Application.put_env(:pincer, :introspection, %{
        "provider" => "minimax"
      })

      messages = [%{"role" => "user", "content" => "reflect"}]
      {:ok, _resp, _usage} = Client.chat_completion(messages, llm_client: LLMStub)

      assert_received {:llm_called, opts}
      assert opts[:provider] == "minimax"
      refute Keyword.has_key?(opts, :model)
      refute Keyword.has_key?(opts, :max_tokens)
    after
      Application.delete_env(:pincer, :introspection)
    end

    test "propagates LLM errors" do
      defmodule ErrorStub do
        def chat_completion(_messages, _opts), do: {:error, :rate_limited}
      end

      messages = [%{"role" => "user", "content" => "reflect"}]
      assert {:error, :rate_limited} = Client.chat_completion(messages, llm_client: ErrorStub)
    end
  end
end
