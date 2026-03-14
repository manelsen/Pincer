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

  defmodule EmptyFinalRecoveredByChatLLM do
    @behaviour Pincer.Ports.LLM

    @impl true
    def chat_completion(_messages, opts) do
      send(self(), {:empty_recovery_chat_opts, opts})
      {:ok, %{"role" => "assistant", "content" => "Estou operacional. Como posso ajudar?"}, nil}
    end

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

  defmodule EmptyFinalRecoveredWithThinkingAndAnswerLLM do
    @behaviour Pincer.Ports.LLM

    @impl true
    def chat_completion(_messages, _opts) do
      {:ok,
       %{
         "role" => "assistant",
         "content" => "<thinking>\nsegredo interno\n</thinking>\n\nOla! Como posso ajudar hoje?"
       }, nil}
    end

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

  defmodule EmptyFinalMustNotRetryLLM do
    @behaviour Pincer.Ports.LLM

    @impl true
    def chat_completion(_messages, _opts) do
      send(self(), :unexpected_chat_retry)
      {:ok, %{"role" => "assistant", "content" => "invented"}, nil}
    end

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

  test "executor recovers first-turn empty stream with a lightweight chat completion" do
    history = [%{"role" => "user", "content" => "Tudo bom contigo?"}]

    Executor.run(self(), "empty_final_recovered_session", history,
      llm_client: EmptyFinalRecoveredByChatLLM
    )

    assert_receive {:empty_recovery_chat_opts, chat_opts}, 1_000
    assert Keyword.get(chat_opts, :tools) in [nil, []]

    assert_receive {:executor_finished, _history, "Estou operacional. Como posso ajudar?",
                    _usage},
                   1_000

    refute_receive {:executor_failed, _}, 200
  end

  test "executor also uses explicit recovery for factual first-turn questions" do
    history = [%{"role" => "user", "content" => "O que tem na pasta atual?"}]

    Executor.run(self(), "empty_final_no_retry_session", history,
      llm_client: EmptyFinalMustNotRetryLLM
    )

    assert_receive :unexpected_chat_retry, 1_000
  end

  test "executor keeps visible answer when empty-response recovery returns thinking plus answer" do
    history = [%{"role" => "user", "content" => "Ei linda"}]

    Executor.run(self(), "empty_final_recovered_with_answer_session", history,
      llm_client: EmptyFinalRecoveredWithThinkingAndAnswerLLM
    )

    assert_receive {:executor_finished, _history, "Ola! Como posso ajudar hoje?", _usage}, 1_000
    refute_receive {:executor_failed, _}, 200
  end
end
