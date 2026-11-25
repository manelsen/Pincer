defmodule Pincer.LLM.RetryEngineTest do
  use ExUnit.Case, async: true

  alias Pincer.LLM.RetryEngine

  defmodule InvalidStreamProvider do
    def stream_completion(_messages, _model, _config, _tools), do: {:ok, :invalid_stream}

    def chat_completion(_messages, model, config, tools) do
      send(self(), {:chat_fallback, model, config, tools})
      {:ok, %{"content" => "fallback"}, nil}
    end
  end

  test "invalid streams use the same request settings for single-shot fallback" do
    request = %{
      adapter: InvalidStreamProvider,
      messages: [],
      model: "configured-model",
      config: %{fixture: true},
      tools: [%{"type" => "function"}],
      failover_state: nil,
      auth_context: nil
    }

    dispatch = fn _, _, _ -> flunk("fallback should use the current route") end

    assert {:ok, [%{"choices" => [%{"delta" => %{"content" => "fallback"}}]}]} =
             RetryEngine.run(:stream_completion, request, dispatch)

    assert_received {:chat_fallback, "configured-model", %{fixture: true},
                     [%{"type" => "function"}]}
  end
end
