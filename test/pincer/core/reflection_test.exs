defmodule Pincer.Core.ReflectionTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.Reflection

  # --- Existing tests (classify/1 and next_prompt/2) ---

  test "classify/1 returns failure when trace has error step" do
    trace = %{"trace" => %{"steps" => [%{"kind" => "memory"}, %{"kind" => "error"}]}}
    assert Reflection.classify(trace) == :failure
  end

  test "next_prompt/2 returns ignore for shallow trace" do
    trace = %{"trace" => %{"steps" => [%{"kind" => "llm"}]}}
    assert Reflection.next_prompt(trace) == :ignore
  end

  test "next_prompt/2 returns prompt for failure trace" do
    trace = %{"trace" => %{"steps" => [%{"kind" => "tool"}, %{"kind" => "error"}]}}
    assert {:ok, prompt} = Reflection.next_prompt(trace)
    assert prompt =~ "auto-reflex"
  end

  # --- reflect/3 tests ---

  defmodule LLMOkStub do
    def chat_completion(_messages, _opts) do
      body =
        Jason.encode!(%{
          focus: "error recovery",
          concerns: ["repeated failures"],
          open_questions: ["is the API down?"],
          summary: "The last turn failed due to a timeout."
        })

      {:ok, %{"content" => body}, %{"prompt_tokens" => 20}}
    end
  end

  defmodule LLMBadJsonStub do
    def chat_completion(_messages, _opts) do
      {:ok, %{"content" => "not valid json at all"}, nil}
    end
  end

  defmodule LLMErrorStub do
    def chat_completion(_messages, _opts) do
      {:error, :rate_limited}
    end
  end

  describe "reflect/3" do
    setup do
      self_state = %Pincer.Core.Introspection.Schema{
        agent_id: "test_agent",
        wakefulness: "idle",
        focus: "",
        concerns: [],
        open_questions: [],
        last_reflection_summary: ""
      }

      %{self_state: self_state}
    end

    test "skips LLM call for shallow trace", %{self_state: self_state} do
      trace = %{steps: [%{kind: "llm"}]}
      assert {:ok, %{action: :skip}} = Reflection.reflect(trace, self_state)
    end

    test "calls LLM and parses JSON for failure trace", %{self_state: self_state} do
      trace = %{steps: [%{kind: "tool"}, %{kind: "error"}]}

      {:ok, result} =
        Reflection.reflect(trace, self_state, introspection_client: LLMOkStub)

      assert result.focus == "error recovery"
      assert result.concerns == ["repeated failures"]
      assert result.open_questions == ["is the API down?"]
      assert result.summary =~ "timeout"
    end

    test "calls LLM for tool_heavy trace", %{self_state: self_state} do
      trace = %{steps: [%{kind: "tool"}, %{kind: "tool"}, %{kind: "tool"}, %{kind: "llm"}]}

      {:ok, result} =
        Reflection.reflect(trace, self_state, introspection_client: LLMOkStub)

      assert result.focus == "error recovery"
    end

    test "graceful fallback on malformed JSON", %{self_state: self_state} do
      trace = %{steps: [%{kind: "tool"}, %{kind: "error"}]}

      {:ok, result} =
        Reflection.reflect(trace, self_state, introspection_client: LLMBadJsonStub)

      assert result.summary == "not valid json at all"
      refute Map.has_key?(result, :focus)
    end

    test "returns error on LLM failure", %{self_state: self_state} do
      trace = %{steps: [%{kind: "tool"}, %{kind: "error"}]}

      assert {:error, :rate_limited} =
               Reflection.reflect(trace, self_state, introspection_client: LLMErrorStub)
    end
  end

  describe "build_reflection_prompt/2" do
    test "returns a list of messages with system and user roles" do
      self_state = %Pincer.Core.Introspection.Schema{
        agent_id: "test",
        wakefulness: "active",
        focus: "debugging",
        concerns: ["flaky test"],
        open_questions: [],
        last_reflection_summary: ""
      }

      trace = %{steps: [%{kind: "error", name: "timeout"}]}
      messages = Reflection.build_reflection_prompt(trace, self_state)

      assert [%{"role" => "system", "content" => sys}, %{"role" => "user", "content" => usr}] =
               messages

      assert sys =~ "JSON"
      assert usr =~ "debugging"
      assert usr =~ "failure"
    end

    test "includes mood in system schema and user message" do
      self_state = %Pincer.Core.Introspection.Schema{
        agent_id: "test",
        wakefulness: "idle",
        focus: "",
        concerns: [],
        open_questions: [],
        last_reflection_summary: "",
        mood_valence: 0.5,
        mood_arousal: 0.8
      }

      trace = %{steps: [%{kind: "tool"}, %{kind: "error"}]}

      [%{"content" => sys}, %{"content" => usr}] =
        Reflection.build_reflection_prompt(trace, self_state)

      assert sys =~ "mood_valence"
      assert sys =~ "mood_arousal"
      assert usr =~ "Mood:"
      assert usr =~ "energized"
    end
  end

  describe "mood in reflection parsing" do
    defmodule LLMWithMoodStub do
      def chat_completion(_messages, _opts) do
        body =
          Jason.encode!(%{
            focus: "stay the course",
            concerns: [],
            open_questions: [],
            summary: "All good.",
            mood_valence: 0.6,
            mood_arousal: 0.3
          })

        {:ok, %{"content" => body}, nil}
      end
    end

    defmodule LLMNoMoodStub do
      def chat_completion(_messages, _opts) do
        body =
          Jason.encode!(%{
            focus: "check errors",
            concerns: ["timeout"],
            open_questions: [],
            summary: "Had a failure."
          })

        {:ok, %{"content" => body}, nil}
      end
    end

    setup do
      self_state = %Pincer.Core.Introspection.Schema{
        agent_id: "mood_test",
        wakefulness: "idle",
        focus: "",
        concerns: [],
        open_questions: [],
        last_reflection_summary: "",
        mood_valence: 0.0,
        mood_arousal: 0.0
      }

      %{self_state: self_state}
    end

    test "extracts mood from LLM response when present", %{self_state: self_state} do
      trace = %{steps: [%{kind: "tool"}, %{kind: "error"}]}

      {:ok, result} =
        Reflection.reflect(trace, self_state, introspection_client: LLMWithMoodStub)

      assert result[:mood_valence] == 0.6
      assert result[:mood_arousal] == 0.3
    end

    test "omits mood keys when LLM doesn't return them", %{self_state: self_state} do
      trace = %{steps: [%{kind: "tool"}, %{kind: "error"}]}

      {:ok, result} =
        Reflection.reflect(trace, self_state, introspection_client: LLMNoMoodStub)

      refute Map.has_key?(result, :mood_valence)
      refute Map.has_key?(result, :mood_arousal)
    end
  end
end
