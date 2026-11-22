defmodule Pincer.Core.Executor.FallbackStrategyTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.Executor.Ctx
  alias Pincer.Core.Executor.FallbackStrategy

  defmodule StubLLM do
    @behaviour Pincer.Ports.LLM

    @impl true
    def chat_completion(messages, opts) do
      send(self(), {:chat_completion, messages, opts})
      {:ok, %{"role" => "assistant", "content" => "fallback answer"}, nil}
    end

    @impl true
    def stream_completion(_messages, _opts), do: {:error, :unused}

    @impl true
    def list_providers, do: []

    @impl true
    def list_models(_provider_id), do: []

    @impl true
    def transcribe_audio(_file_path, _opts), do: {:error, :not_implemented}

    @impl true
    def provider_config("fallback_probe"), do: %{context_window: 8_000}

    @impl true
    def provider_config(_provider_id), do: nil
  end

  defmodule FailingLLM do
    @behaviour Pincer.Ports.LLM

    @impl true
    def chat_completion(_messages, _opts), do: {:error, :backend_down}

    @impl true
    def stream_completion(_messages, _opts), do: {:error, :unused}

    @impl true
    def list_providers, do: []

    @impl true
    def list_models(_provider_id), do: []

    @impl true
    def transcribe_audio(_file_path, _opts), do: {:error, :not_implemented}

    @impl true
    def provider_config(_provider_id), do: nil
  end

  defmodule RegistryStub do
    @behaviour Pincer.Ports.ToolRegistry

    @impl true
    def list_tools, do: []

    @impl true
    def execute_tool(_name, _args, _context), do: {:ok, "unused"}
  end

  setup do
    history = [
      %{"role" => "system", "content" => "You are a bot"},
      %{"role" => "user", "content" => "hello"}
    ]

    ctx =
      Ctx.new(self(), "fallback_strategy_test_session",
        llm_client: StubLLM,
        tool_registry: RegistryStub,
        workspace_path: "tmp/test_workspaces/fallback_strategy"
      )

    %{history: history, ctx: ctx}
  end

  defp finalize_recorder do
    fun = fn msg, logical, prompt, depth, ctx, usage, opts ->
      send(self(), {:finalized, msg, logical, prompt, depth, opts})
      {:ok, logical ++ [msg], msg["content"], usage, ctx}
    end

    fun
  end

  defp prepare_identity, do: fn history, ctx, _opts -> {history, ctx} end

  test "build_request keeps tools when the reason is unrelated to tools", %{
    history: history,
    ctx: ctx
  } do
    tools = [%{"name" => "my_tool"}]

    assert {^history, opts, ^ctx} =
             FallbackStrategy.build_request(
               :unexpected_response_format,
               history,
               history,
               ctx,
               [temperature: 0.1],
               tools,
               prepare_identity()
             )

    assert opts == [tools: tools, temperature: 0.1]
  end

  test "build_request drops tools when the provider rejects tool calling", %{
    history: history,
    ctx: ctx
  } do
    tools = [%{"name" => "my_tool"}]
    reason = {:http_error, 400, ~s({"error":{"message":"`tool calling` is not supported"}})}

    assert {^history, [temperature: 0.1], ^ctx} =
             FallbackStrategy.build_request(
               reason,
               history,
               history,
               ctx,
               [temperature: 0.1],
               tools,
               prepare_identity()
             )
  end

  test "build_request rebuilds the prompt on context overflow and drops tools", %{
    history: history,
    ctx: ctx
  } do
    tools = [%{"name" => "my_tool"}]
    reason = {:http_error, 400, "maximum context length exceeded"}

    parent = self()

    prepare = fn history, ctx, opts ->
      send(parent, {:prepare_opts, opts})
      {[:rebuilt | history], ctx}
    end

    assert {[:rebuilt | ^history], [temperature: 0.1], ^ctx} =
             FallbackStrategy.build_request(
               reason,
               history,
               history,
               ctx,
               [temperature: 0.1],
               tools,
               prepare
             )

    assert_received {:prepare_opts, opts}
    assert Keyword.has_key?(opts, :safe_limit_scale)
  end

  test "run delegates the chat result to the finalizer", %{history: history, ctx: ctx} do
    assert {:ok, _history, "fallback answer", nil, _ctx} =
             FallbackStrategy.run(
               :stream_down,
               history,
               history,
               0,
               ctx,
               [],
               [],
               prepare_history: prepare_identity(),
               finalize: finalize_recorder()
             )

    assert_received {:chat_completion, _messages, opts}
    assert opts == [tools: []]

    assert_received {:finalized, msg, _logical, _prompt, 0, finalize_opts}
    assert msg["content"] == "fallback answer"
    assert finalize_opts == []
  end

  test "run forwards the original histories to the finalizer untouched", %{
    history: history,
    ctx: ctx
  } do
    tools = [%{"name" => "my_tool"}]
    ctx = %{ctx | model_override: nil}

    assert {:ok, _history, "fallback answer", nil, _ctx} =
             FallbackStrategy.run(
               :stream_down,
               history,
               [:prompt | history],
               2,
               ctx,
               [],
               tools,
               prepare_history: prepare_identity(),
               finalize: finalize_recorder()
             )

    assert_received {:finalized, _msg, logical, prompt, 2, []}
    assert logical == history
    assert prompt == [:prompt | history]
  end

  test "run returns the error and traces it when the fallback call fails", %{
    history: history,
    ctx: ctx
  } do
    ctx = %{ctx | deps: %{ctx.deps | llm_client: FailingLLM}}

    assert {:error, :backend_down, traced_ctx} =
             FallbackStrategy.run(
               :stream_down,
               history,
               history,
               0,
               ctx,
               [],
               [],
               prepare_history: prepare_identity(),
               finalize: finalize_recorder()
             )

    refute_received {:finalized, _, _, _, _, _}
    assert traced_ctx.deps.llm_client == FailingLLM
  end
end
