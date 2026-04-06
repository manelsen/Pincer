defmodule Pincer.Core.Introspection.LessonExtractorTest do
  use ExUnit.Case, async: false

  alias Pincer.Core.Introspection.LessonExtractor

  @agent "extractor_test_agent"

  setup do
    Pincer.Infra.Repo.delete_all(Pincer.Core.Introspection.LessonSchema)
    :ok
  end

  defmodule LLMOkStub do
    def chat_completion(_messages, _opts) do
      body =
        Jason.encode!(%{
          lessons: [
            %{content: "Always validate tool output before returning.", confidence: 0.7},
            %{content: "Retry transient failures with backoff.", confidence: 0.6}
          ]
        })

      {:ok, %{"content" => body}, nil}
    end
  end

  defmodule LLMEmptyStub do
    def chat_completion(_messages, _opts) do
      {:ok, %{"content" => Jason.encode!(%{lessons: []})}, nil}
    end
  end

  defmodule LLMBadJsonStub do
    def chat_completion(_messages, _opts) do
      {:ok, %{"content" => "not json"}, nil}
    end
  end

  defmodule LLMErrorStub do
    def chat_completion(_messages, _opts), do: {:error, :timeout}
  end

  describe "extract/3" do
    test "extracts lessons from trace and persists them" do
      trace = %{steps: [%{kind: "tool"}, %{kind: "error"}]}

      {:ok, lessons} =
        LessonExtractor.extract(@agent, trace, introspection_client: LLMOkStub)

      assert length(lessons) == 2
      assert hd(lessons).content =~ "validate tool output"
    end

    test "deduplicates against existing lessons" do
      trace = %{steps: [%{kind: "error"}]}

      {:ok, [_l1, _l2]} =
        LessonExtractor.extract(@agent, trace, introspection_client: LLMOkStub)

      # Extract again — same lessons should be rejected as duplicates
      {:ok, new_lessons} =
        LessonExtractor.extract(@agent, trace, introspection_client: LLMOkStub)

      assert new_lessons == []
    end

    test "returns empty list when LLM returns no lessons" do
      trace = %{steps: [%{kind: "tool"}]}

      {:ok, lessons} =
        LessonExtractor.extract(@agent, trace, introspection_client: LLMEmptyStub)

      assert lessons == []
    end

    test "handles malformed LLM response gracefully" do
      trace = %{steps: [%{kind: "error"}]}

      {:ok, lessons} =
        LessonExtractor.extract(@agent, trace, introspection_client: LLMBadJsonStub)

      assert lessons == []
    end

    test "returns error on LLM failure" do
      trace = %{steps: [%{kind: "error"}]}

      assert {:error, :timeout} =
               LessonExtractor.extract(@agent, trace, introspection_client: LLMErrorStub)
    end
  end
end
