defmodule Pincer.Core.Introspection.ClientTest do
  use ExUnit.Case, async: false

  alias Pincer.Core.Introspection.Client

  defmodule LLMStub do
    def chat_completion(_messages, opts) do
      send(self(), {:llm_called, opts})
      {:ok, %{"content" => "reflection result"}, %{"prompt_tokens" => 10}}
    end
  end

  setup do
    prev_intro = Application.get_env(:pincer, :introspection, :__unset__)
    prev_default = Application.get_env(:pincer, :default_llm_provider, :__unset__)

    on_exit(fn ->
      case prev_intro do
        :__unset__ -> Application.delete_env(:pincer, :introspection)
        val -> Application.put_env(:pincer, :introspection, val)
      end

      case prev_default do
        :__unset__ -> Application.delete_env(:pincer, :default_llm_provider)
        val -> Application.put_env(:pincer, :default_llm_provider, val)
      end
    end)

    :ok
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
    end

    test "routes reflection locally when session uses a local provider instead of leaking to cloud introspection" do
      Application.put_env(:pincer, :introspection, %{
        "provider" => "groq",
        "model" => "llama-3.1-8b-instant",
        "max_tokens" => 512
      })

      messages = [%{"role" => "user", "content" => "sensitive local trace"}]

      {:ok, _resp, _usage} =
        Client.chat_completion(messages,
          llm_client: LLMStub,
          session_model_override: %{provider: "ollama", model: "llama3.2:latest"}
        )

      assert_received {:llm_called, opts}
      assert opts[:provider] == "ollama"
      assert opts[:model] == "llama3.2:latest"
      assert opts[:max_tokens] == 512
      refute Keyword.has_key?(opts, :session_model_override)
    end

    test "blocks cloud dispatch when locality is local_only and neither target is local" do
      Application.put_env(:pincer, :introspection, %{
        "provider" => "groq",
        "model" => "llama-3.1-8b-instant",
        "locality" => "local_only"
      })

      messages = [%{"role" => "user", "content" => "reflect"}]

      assert {:error, :non_local_introspection_blocked} =
               Client.chat_completion(messages,
                 llm_client: LLMStub,
                 session_model_override: %{provider: "openrouter", model: "claude"}
               )

      refute_received {:llm_called, _}
    end

    test "effective_target/1 reports active introspection provider and local inheritance" do
      Application.put_env(:pincer, :introspection, %{
        "provider" => "groq",
        "model" => "llama-3.1-8b-instant"
      })

      assert %{provider: "groq", model: "llama-3.1-8b-instant", locality: :configured} =
               Client.effective_target(nil)

      assert %{provider: "ollama", model: "qwen2.5:7b", locality: :local_session} =
               Client.effective_target(%{provider: "ollama", model: "qwen2.5:7b"})
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
