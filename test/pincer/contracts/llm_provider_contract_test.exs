defmodule Pincer.Contracts.LLMProviderContractTest do
  use ExUnit.Case, async: true

  @provider_modules [
    Pincer.LLM.Providers.OpenAICompat,
    Pincer.LLM.Providers.OpenRouter,
    Pincer.LLM.Providers.Zhipu,
    Pincer.LLM.Providers.DeepSeek,
    Pincer.LLM.Providers.Moonshot,
    Pincer.LLM.Providers.Qwen,
    Pincer.LLM.Providers.OpencodeZen,
    Pincer.LLM.Providers.Google,
    Pincer.LLM.Providers.Anthropic
  ]

  @messages [%{"role" => "user", "content" => "ping"}]

  test "provider adapters declare LLM provider behaviour and callbacks" do
    Enum.each(@provider_modules, fn provider_module ->
      behaviours = provider_module.module_info(:attributes)[:behaviour] || []

      assert Pincer.LLM.Provider in behaviours
      assert function_exported?(provider_module, :chat_completion, 4)
      assert function_exported?(provider_module, :stream_completion, 4)
    end)
  end

  test "provider adapters respect tuple contract without raising on empty config" do
    Enum.each(@provider_modules, fn provider_module ->
      chat_result = provider_module.chat_completion(@messages, "model", %{}, [])
      assert match?({:ok, _, _}, chat_result) or match?({:error, _}, chat_result)

      stream_result = provider_module.stream_completion(@messages, "model", %{}, [])
      assert match?({:ok, _}, stream_result) or match?({:error, _}, stream_result)
    end)
  end
end
