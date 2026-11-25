defmodule PincerPorts.LLMTest do
  use ExUnit.Case, async: false

  alias PincerPorts.LLM

  defmodule Adapter do
    @behaviour LLM

    @impl LLM
    def chat_completion(history, opts), do: {:ok, %{history: history, opts: opts}, nil}

    @impl LLM
    def stream_completion(history, _opts), do: {:ok, history}

    @impl LLM
    def list_providers, do: [%{id: "test", name: "Test Provider"}]

    @impl LLM
    def list_models("test"), do: ["test-model"]

    @impl LLM
    def provider_config("test"), do: %{model: "test-model"}

    @impl LLM
    def transcribe_audio(_path, _opts), do: {:error, :file_not_found}

    def generate_embedding(_text, _opts), do: {:ok, [1.0]}
  end

  setup do
    previous = Application.fetch_env(:pincer, :llm_adapter)
    Application.put_env(:pincer, :llm_adapter, Adapter)

    on_exit(fn ->
      case previous do
        {:ok, adapter} -> Application.put_env(:pincer, :llm_adapter, adapter)
        :error -> Application.delete_env(:pincer, :llm_adapter)
      end
    end)
  end

  test "dispatches provider discovery, completion, embeddings and transcription to the host adapter" do
    assert LLM.list_providers() == [%{id: "test", name: "Test Provider"}]
    assert LLM.list_models("test") == ["test-model"]
    assert LLM.provider_config("test") == %{model: "test-model"}

    history = [%{role: "user", content: "Hello"}]
    assert LLM.chat_completion(history) == {:ok, %{history: history, opts: []}, nil}
    assert LLM.stream_completion(history, provider: "test") == {:ok, history}
    assert LLM.generate_embedding("Hello") == {:ok, [1.0]}
    assert LLM.transcribe_audio("missing.ogg") == {:error, :file_not_found}
  end

  test "raises when the host has not configured an adapter" do
    Application.delete_env(:pincer, :llm_adapter)
    assert_raise ArgumentError, ~r/missing :llm_adapter/, &LLM.list_providers/0

    Application.put_env(:pincer, :llm_adapter, nil)
    assert_raise ArgumentError, ~r/invalid :llm_adapter/, &LLM.list_providers/0
  end
end
