defmodule Pincer.Core.Session.BlackboardTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.Session.Blackboard, as: SessionBlackboard
  alias Pincer.Core.Structs.Usage

  defmodule LLMStub do
    def chat_completion(_history, _opts) do
      case Process.get(:blackboard_llm_result) do
        fun when is_function(fun, 0) -> fun.()
        other -> other
      end
    end
  end

  describe "format_message/1" do
    test "formats structured :plan_generated messages" do
      msg = %{
        kind: :plan_generated,
        project_id: "p-1",
        content: "PLAN_GENERATED:\nTask A\nTask B"
      }

      formatted = SessionBlackboard.format_message(msg)

      assert formatted =~ "Suggested Project Plan (p-1)"
      assert formatted =~ "Task A\nTask B"
      assert formatted =~ "/project approve p-1"
    end

    test "formats structured :error_diagnostic messages" do
      msg = %{kind: :error_diagnostic, project_id: "p-2", content: "ERROR_DIAGNOSTIC: timeout"}
      formatted = SessionBlackboard.format_message(msg)

      assert formatted =~ "CRITICAL PROJECT FAILURE (p-2)"
      assert formatted =~ "`timeout`"
      assert formatted =~ "/project resume p-2"
    end

    test "falls back to legacy prefix matching when kind is missing" do
      plan_msg = %{project_id: "p-legacy", content: "PLAN_GENERATED:\nStep 1"}
      err_msg = %{project_id: "p-legacy", content: "ERROR_DIAGNOSTIC: crash"}

      assert SessionBlackboard.format_message(plan_msg) =~ "Suggested Project Plan (p-legacy)"
      assert SessionBlackboard.format_message(err_msg) =~ "CRITICAL PROJECT FAILURE (p-legacy)"
    end

    test "formats generic messages with project_id or GLOBAL fallback" do
      assert SessionBlackboard.format_message(%{project_id: "p-3", content: "hi"}) == "[p-3]: hi"
      assert SessionBlackboard.format_message(%{content: "broadcast"}) == "[GLOBAL]: broadcast"
    end
  end

  describe "ingest/3" do
    test "appends blackboard system update and advances SubAgentProgress tracker" do
      history = [%{"role" => "system", "content" => "SYS"}]

      messages = [
        %{agent_id: "sub_1", content: "Started with goal: audit"},
        %{agent_id: "sub_1", content: "FINISHED: all clear"},
        %{
          agent_id: "Architect",
          project_id: "p-1",
          kind: :plan_generated,
          content: "PLAN_GENERATED:\nTask 1"
        }
      ]

      result = SessionBlackboard.ingest(history, %{}, messages)

      assert length(result.history) == 2
      assert List.last(result.history)["role"] == "system"
      assert List.last(result.history)["content"] =~ "SYSTEM UPDATE (Blackboard):"
      assert List.last(result.history)["content"] =~ "Suggested Project Plan (p-1)"
      assert result.needs_review? == true
      assert length(result.notifications) == 2
      assert result.tracker["sub_1"].terminal? == true
    end
  end

  describe "evaluate_update/3" do
    test "returns {:reply, content, %Usage{}} when model replies meaningfully and sends zero messages" do
      Process.put(
        :blackboard_llm_result,
        {:ok, %{"content" => "Heads up: build failed."},
         %{"prompt_tokens" => 5, "completion_tokens" => 3}}
      )

      on_exit(fn -> Process.delete(:blackboard_llm_result) end)

      result =
        SessionBlackboard.evaluate_update(
          [%{"role" => "system", "content" => "update"}],
          %{provider: "z_ai", model: "glm-4"},
          llm_client: LLMStub
        )

      assert {:reply, "Heads up: build failed.",
              %Usage{prompt_tokens: 5, completion_tokens: 3, total_tokens: 8}} = result

      assert {:messages, []} = Process.info(self(), :messages)
    end

    test "preserves nil usage when provider omits usage" do
      Process.put(:blackboard_llm_result, {:ok, %{"content" => "Update"}, nil})
      on_exit(fn -> Process.delete(:blackboard_llm_result) end)

      assert {:reply, "Update", nil} ==
               SessionBlackboard.evaluate_update([], nil, llm_client: LLMStub)
    end

    test "returns :ignore for IGNORE (case-insensitive / trimmed) or nil content" do
      for payload <- [
            {:ok, %{"content" => "IGNORE"}, nil},
            {:ok, %{"content" => "  ignore \n"}, nil},
            {:ok, %{"content" => nil}, nil},
            {:ok, %{}, nil}
          ] do
        Process.put(:blackboard_llm_result, payload)
        assert :ignore == SessionBlackboard.evaluate_update([], nil, llm_client: LLMStub)
      end

      Process.delete(:blackboard_llm_result)
    end

    test "returns {:error, reason} when llm_client fails" do
      Process.put(:blackboard_llm_result, {:error, :rate_limited})
      on_exit(fn -> Process.delete(:blackboard_llm_result) end)

      assert {:error, :rate_limited} ==
               SessionBlackboard.evaluate_update([], nil, llm_client: LLMStub)
    end
  end
end
