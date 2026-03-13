defmodule Pincer.Core.ExecutorEmptyResponseTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.Executor

  defmodule EmptyFinalLLM do
    @behaviour Pincer.Ports.LLM

    @impl true
    def chat_completion(_messages, _opts), do: {:error, :not_implemented}

    @impl true
    def stream_completion(_messages, _opts) do
      {:ok, [%{"choices" => [%{"delta" => %{}}]}]}
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

  test "executor fails when provider finishes with empty final content and no tool calls" do
    history = [%{"role" => "user", "content" => "Boa noite!"}]

    Executor.run(self(), "empty_final_response_session", history, llm_client: EmptyFinalLLM)

    assert_receive {:executor_failed, :empty_response}, 1_000
    refute_receive {:executor_finished, _, _, _}, 200
  end
end
