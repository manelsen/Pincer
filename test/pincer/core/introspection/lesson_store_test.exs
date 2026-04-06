defmodule Pincer.Core.Introspection.LessonStoreTest do
  use ExUnit.Case, async: false

  alias Pincer.Core.Introspection.LessonStore

  @agent "lesson_test_agent"

  setup do
    Pincer.Infra.Repo.delete_all(Pincer.Core.Introspection.LessonSchema)
    :ok
  end

  describe "create/2" do
    test "inserts a new lesson" do
      {:ok, lesson} = LessonStore.create(@agent, %{content: "Always check errors."})
      assert lesson.agent_id == @agent
      assert lesson.content == "Always check errors."
      assert lesson.confidence == 0.5
      assert lesson.active == true
    end

    test "rejects duplicate by novelty check" do
      {:ok, _} = LessonStore.create(@agent, %{content: "Always check errors."})
      assert {:error, :duplicate} = LessonStore.create(@agent, %{content: "Always check errors."})
    end

    test "accepts sufficiently novel lesson" do
      {:ok, _} = LessonStore.create(@agent, %{content: "Always check errors."})
      {:ok, l2} = LessonStore.create(@agent, %{content: "Use structured logging for debugging."})
      assert l2.content == "Use structured logging for debugging."
    end
  end

  describe "top_lessons/2" do
    test "returns lessons ordered by confidence descending" do
      {:ok, _} = LessonStore.create(@agent, %{content: "Lesson low", confidence: 0.3})
      {:ok, _} = LessonStore.create(@agent, %{content: "Lesson high", confidence: 0.9})
      {:ok, _} = LessonStore.create(@agent, %{content: "Lesson mid", confidence: 0.6})

      top = LessonStore.top_lessons(@agent, 2)
      assert length(top) == 2
      assert hd(top).confidence == 0.9
    end

    test "excludes inactive lessons" do
      {:ok, lesson} = LessonStore.create(@agent, %{content: "Inactive one", confidence: 0.9})
      LessonStore.deactivate(lesson.id)

      {:ok, _} = LessonStore.create(@agent, %{content: "Active one", confidence: 0.5})

      top = LessonStore.top_lessons(@agent, 10)
      assert length(top) == 1
      assert hd(top).content == "Active one"
    end

    test "filters by minimum confidence threshold" do
      {:ok, _} = LessonStore.create(@agent, %{content: "Low confidence", confidence: 0.2})
      {:ok, _} = LessonStore.create(@agent, %{content: "High confidence", confidence: 0.8})

      top = LessonStore.top_lessons(@agent, 10, min_confidence: 0.5)
      assert length(top) == 1
      assert hd(top).content == "High confidence"
    end
  end

  describe "record_outcome/2" do
    test "increments success_count on positive outcome" do
      {:ok, lesson} = LessonStore.create(@agent, %{content: "Test lesson"})
      {:ok, updated} = LessonStore.record_outcome(lesson.id, :success)
      assert updated.success_count == 1
      assert updated.last_outcome == "success"
    end

    test "increments failure_count on negative outcome" do
      {:ok, lesson} = LessonStore.create(@agent, %{content: "Test lesson"})
      {:ok, updated} = LessonStore.record_outcome(lesson.id, :failure)
      assert updated.failure_count == 1
      assert updated.last_outcome == "failure"
    end

    test "recalculates confidence after outcome" do
      {:ok, lesson} = LessonStore.create(@agent, %{content: "Test lesson", confidence: 0.5})
      {:ok, _} = LessonStore.record_outcome(lesson.id, :success)
      {:ok, _} = LessonStore.record_outcome(lesson.id, :success)
      {:ok, updated} = LessonStore.record_outcome(lesson.id, :success)
      # With 3 successes and 0 failures, confidence should increase
      assert updated.confidence > 0.5
    end
  end

  describe "jaccard_similarity/2" do
    test "identical strings return 1.0" do
      assert LessonStore.jaccard_similarity("hello world", "hello world") == 1.0
    end

    test "completely different strings return 0.0" do
      assert LessonStore.jaccard_similarity("aaa bbb", "ccc ddd") == 0.0
    end

    test "partial overlap returns value between 0 and 1" do
      sim = LessonStore.jaccard_similarity("always check errors", "always handle errors")
      assert sim > 0.0
      assert sim < 1.0
    end
  end

  describe "recalculate_confidence/1" do
    test "combines scoring factors" do
      {:ok, lesson} =
        LessonStore.create(@agent, %{
          content: "Recalc test",
          extraction_confidence: 0.8,
          success_count: 5,
          failure_count: 1
        })

      score = LessonStore.recalculate_confidence(lesson)
      assert is_float(score)
      assert score >= 0.0
      assert score <= 1.0
    end
  end
end
