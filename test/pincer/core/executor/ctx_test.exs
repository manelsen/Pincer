defmodule Pincer.Core.Executor.CtxTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.AgentPaths
  alias Pincer.Core.Executor.Attachments
  alias Pincer.Core.Executor.Ctx

  describe "new/3" do
    test "resolves defaults and normalizes string-keyed model_override" do
      ctx =
        Ctx.new(self(), "ctx_session_1",
          model_override: %{
            "provider" => "z_ai_coding",
            "model" => "glm-4.7",
            "thinking_level" => "medium"
          }
        )

      assert ctx.session_pid == self()
      assert ctx.session_id == "ctx_session_1"
      assert ctx.workspace_path == AgentPaths.workspace_root("ctx_session_1")
      assert ctx.deps.llm_client == Pincer.Ports.LLM
      assert ctx.deps.tool_registry == Pincer.Ports.ToolRegistry
      assert ctx.deps.storage == Pincer.Ports.Storage
      assert ctx.deps.file_fetcher == (&Attachments.default_fetch/1)
      assert is_integer(ctx.deps.max_depth)
      assert ctx.consecutive_errors == 0
      assert ctx.trace == nil

      assert ctx.model_override == %{
               provider: "z_ai_coding",
               model: "glm-4.7",
               thinking_level: "medium"
             }
    end

    test "accepts explicit overrides and normalizes incomplete model_override to nil" do
      ref = make_ref()

      ctx =
        Ctx.new(self(), "ctx_session_2",
          ref: ref,
          workspace_path: "/tmp/custom_ws",
          llm_client: __MODULE__,
          tool_registry: __MODULE__,
          storage: __MODULE__,
          max_depth: 7,
          context_strategy: :conversation_summary,
          long_term_memory: "remember this",
          model_override: %{"provider" => "only_provider"}
        )

      assert ctx.ref == ref
      assert ctx.workspace_path == "/tmp/custom_ws"
      assert ctx.deps.llm_client == __MODULE__
      assert ctx.deps.tool_registry == __MODULE__
      assert ctx.deps.storage == __MODULE__
      assert ctx.deps.max_depth == 7
      assert ctx.context_strategy == :conversation_summary
      assert ctx.long_term_memory == "remember this"
      assert ctx.model_override == nil
    end

    test "resolves agent_id and channel from opts, conversation_ref, or session prefix" do
      paired =
        Ctx.new(self(), "telegram_123",
          root_agent_id: "annie",
          channel: :telegram
        )

      assert paired.agent_id == "annie"
      assert paired.channel == "telegram"

      by_agent =
        Ctx.new(self(), "telegram_456",
          agent_id: "lucie",
          conversation_ref: "discord:dm:456"
        )

      assert by_agent.agent_id == "lucie"
      assert by_agent.channel == "discord"

      by_session_prefix = Ctx.new(self(), "telegram_789")
      assert by_session_prefix.agent_id == "telegram_789"
      assert by_session_prefix.channel == "telegram"

      generic = Ctx.new(self(), "ctx_session_generic")
      assert generic.agent_id == "ctx_session_generic"
      assert generic.channel == nil
    end
  end

  describe "model override and client_opts/active_provider" do
    test "with_model_override/3 updates provider and model and client_opts/1 builds keyword opts" do
      ctx =
        Ctx.new(self(), "ctx_session_3")
        |> Ctx.with_model_override("groq", "llama-3.3-70b")

      assert ctx.model_override == %{provider: "groq", model: "llama-3.3-70b"}
      assert Ctx.client_opts(ctx) == [provider: "groq", model: "llama-3.3-70b"]
      assert Ctx.active_provider(ctx) == "groq"

      ctx_with_thinking =
        Ctx.new(self(), "ctx_session_3b",
          model_override: %{provider: "anthropic", model: "claude", thinking_level: "high"}
        )

      assert Ctx.client_opts(ctx_with_thinking) == [
               thinking_level: "high",
               provider: "anthropic",
               model: "claude"
             ]
    end

    test "client_opts/1 returns empty list when model_override is nil" do
      ctx = Ctx.new(self(), "ctx_session_4")
      assert Ctx.client_opts(ctx) == []
      assert is_binary(Ctx.active_provider(ctx))
    end
  end

  describe "trace helpers and consecutive error tracking" do
    test "records, appends, and emits trace snapshot when trace_events? is true" do
      ctx =
        Ctx.new(self(), "ctx_trace_1", trace_events?: true, max_depth: 5)
        |> Ctx.record_trace(:checkpoint, "turn_started", %{history_size: 2})
        |> Ctx.append_trace_steps([{:tool, "tool_invoked", %{tool: "safe_shell"}}])

      assert_received {:executor_trace_step, :checkpoint, "turn_started", %{history_size: 2}}
      refute_received {:executor_trace_step, :tool, "tool_invoked", _}

      assert :ok = Ctx.emit_trace_snapshot(ctx)
      assert_received {:executor_trace, %{"trace" => trace}}
      assert length(trace["steps"]) == 2
    end

    test "trace helpers are no-ops when trace_events? is false" do
      ctx =
        Ctx.new(self(), "ctx_trace_2")
        |> Ctx.record_trace(:checkpoint, "turn_started", %{})
        |> Ctx.append_trace_steps([{:tool, "tool_invoked", %{}}])

      assert ctx.trace == nil
      assert :ok = Ctx.emit_trace_snapshot(ctx)
      refute_received {:executor_trace_step, _, _, _}
      refute_received {:executor_trace, _}
    end

    test "record_tool_outcome/2 increments on error and resets on ok" do
      ctx =
        Ctx.new(self(), "ctx_err_1")
        |> Ctx.record_tool_outcome(:error)
        |> Ctx.record_tool_outcome(:error)

      assert ctx.consecutive_errors == 2

      reset_ctx = Ctx.record_tool_outcome(ctx, :ok)
      assert reset_ctx.consecutive_errors == 0
    end
  end
end
