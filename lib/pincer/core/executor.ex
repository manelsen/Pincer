defmodule Pincer.Core.Executor do
  @moduledoc """
  The Unified Executor — orchestrates the agentic reasoning and tool-use loop.

  The Executor threads an explicit `%Pincer.Core.Executor.Ctx{}` across pure
  policies (`LoopGuard`, `Policy`, `TurnOutcomePolicy`,
  `EmptyResponseRecoveryPolicy`, `ToolAnswerPatternPolicy`) and focused execution
  collaborators (`StreamAccumulator`, `ToolCall`, `ToolRunner`, `Attachments`).
  """

  require Logger

  alias Pincer.Core.EmptyResponseRecoveryPolicy
  alias Pincer.Core.Executor.Attachments
  alias Pincer.Core.Executor.Ctx
  alias Pincer.Core.Executor.FallbackStrategy
  alias Pincer.Core.Executor.LoopGuard
  alias Pincer.Core.Executor.StreamAccumulator
  alias Pincer.Core.Executor.ToolCall
  alias Pincer.Core.Executor.ToolRunner
  alias Pincer.Core.MemoryRecall
  alias Pincer.Core.Policy
  alias Pincer.Core.PromptAssembly
  alias PincerPorts.Structs.Usage
  alias Pincer.Core.ToolAnswerPatternPolicy
  alias Pincer.Core.ToolOnlyOutcomeFormatter
  alias Pincer.Core.TurnOutcomePolicy
  alias Pincer.Utils.Text

  @type outcome ::
          {:ok, [map()], String.t(), Usage.t() | nil} | {:error, term()}

  @doc """
  Runs the executor cycle for `session_id`, optionally notifying `session_pid`
  once upon completion (`notify?: true` by default) and returning the outcome.
  """
  @spec run(pid() | nil, String.t(), [map()], keyword()) :: outcome()
  def run(session_pid, session_id, history, opts \\ []) do
    ctx =
      session_pid
      |> Ctx.new(session_id, opts)
      |> Ctx.record_trace(:checkpoint, "turn_started", %{history_size: length(history)})

    notify? = Keyword.get(opts, :notify?, true)
    Logger.info("[EXECUTOR] Starting cycle for #{session_id}")

    case run_loop(history, nil, 0, ctx) do
      {:ok, final_history, final_content, usage, final_ctx} ->
        normalized_usage = Usage.normalize_optional(usage)

        final_ctx =
          Ctx.record_trace(final_ctx, :checkpoint, "turn_finished", %{
            final_history_size: length(final_history),
            has_usage: not is_nil(normalized_usage)
          })

        Ctx.emit_trace_snapshot(final_ctx)
        if notify?, do: notify_finished(final_ctx, final_history, final_content, normalized_usage)
        {:ok, final_history, final_content, normalized_usage}

      {:error, reason, final_ctx} ->
        final_ctx = Ctx.record_trace(final_ctx, :error, "turn_failed", %{reason: inspect(reason)})
        Ctx.emit_trace_snapshot(final_ctx)
        if notify?, do: notify_failed(final_ctx, reason)
        {:error, reason}
    end
  end

  @doc """
  Spawns a linked executor process running `run/4`.
  """
  @spec start(pid() | nil, String.t(), [map()], keyword()) :: {:ok, pid()}
  def start(session_pid, session_id, history, opts \\ []) do
    pid = spawn_link(fn -> run(session_pid, session_id, history, opts) end)
    {:ok, pid}
  end

  @doc false
  defdelegate resolve_attachment_url(url, token), to: Attachments, as: :resolve_url

  @doc false
  defdelegate default_file_fetch(url), to: Attachments, as: :default_fetch

  # --- Execution Loop ---

  defp run_loop(logical_history, prompt_history, depth, %Ctx{} = ctx) do
    case LoopGuard.check(logical_history, depth, ctx.deps.max_depth) do
      :ok ->
        {prompt_history, ctx} = ensure_prompt_history(logical_history, prompt_history, ctx)
        ctx = drain_model_changes(ctx)
        do_run_loop(logical_history, prompt_history, depth, ctx)

      {:error, {:depth_exceeded, ^depth} = reason} ->
        Logger.warning("[EXECUTOR] Depth limit reached (#{depth}/#{ctx.deps.max_depth})")
        {:error, reason, ctx}

      {:error, :tool_loop} ->
        {:error, :tool_loop, ctx}
    end
  end

  defp ensure_prompt_history(_logical_history, prompt_history, ctx)
       when not is_nil(prompt_history),
       do: {prompt_history, ctx}

  defp ensure_prompt_history(logical_history, nil, ctx) do
    prepare_prompt_history(logical_history, ctx)
  end

  defp drain_model_changes(%Ctx{} = ctx) do
    receive do
      {:model_changed, provider, model} ->
        Logger.info("[EXECUTOR] Model override updated mid-session: #{provider}:#{model}")

        ctx
        |> Ctx.with_model_override(provider, model)
        |> drain_model_changes()
    after
      0 -> ctx
    end
  end

  @doc false
  def prepare_prompt_history(history, %Ctx{} = ctx, opts \\ []) do
    provider_name = Ctx.active_provider(ctx)

    provider_config =
      (Application.get_env(:pincer, :llm_providers, %{}) || %{})
      |> Map.get(provider_name, %{})

    prepared_history =
      history
      |> PromptAssembly.prepare(ctx.model_override,
        long_term_memory: ctx.long_term_memory,
        current_time: DateTime.utc_now() |> DateTime.to_string(),
        workspace_path: ctx.workspace_path,
        session_id: ctx.session_id,
        llm_client: Pincer.Ports.LLM,
        storage: ctx.deps.storage,
        memory_recall: MemoryRecall,
        safe_limit_scale: Keyword.get(opts, :safe_limit_scale, 1.0),
        context_strategy: ctx.context_strategy
      )
      |> Attachments.resolve_history(provider_config, ctx.deps.file_fetcher)

    ctx =
      Ctx.record_trace(ctx, :memory, "prompt_prepared", %{
        messages: length(prepared_history),
        provider: provider_name
      })

    {prepared_history, ctx}
  end

  defp do_run_loop(logical_history, prompt_history, depth, %Ctx{} = ctx) do
    Logger.info("[EXECUTOR] do_run_loop (Depth: #{depth})")

    client_opts = Ctx.client_opts(ctx)
    tools_spec = ctx.deps.tool_registry.list_tools() |> ToolCall.clean_specs()

    Logger.info(
      "[EXECUTOR] Sending prompt to LLM (STREAMING). History size: #{length(prompt_history)}"
    )

    ctx =
      ctx
      |> Ctx.record_trace(:policy, "llm_request_prepared", %{
        depth: depth,
        tools: length(tools_spec)
      })
      |> Ctx.record_trace(:llm, "stream_completion_invoked", %{depth: depth})

    case ctx.deps.llm_client.stream_completion(prompt_history, [tools: tools_spec] ++ client_opts) do
      {:ok, stream, stream_usage} ->
        run_stream(
          stream,
          stream_usage,
          logical_history,
          prompt_history,
          depth,
          ctx,
          client_opts,
          tools_spec
        )

      {:ok, stream} ->
        run_stream(
          stream,
          nil,
          logical_history,
          prompt_history,
          depth,
          ctx,
          client_opts,
          tools_spec
        )

      {:error, {:missing_credentials, _env_key} = cred_error} ->
        Logger.warning("[EXECUTOR] LLM call failed: #{inspect(cred_error)}")
        {:error, cred_error, ctx}

      {:error, reason} ->
        Logger.error("[EXECUTOR] LLM streaming failed: #{inspect(reason)}")

        ctx =
          Ctx.record_trace(ctx, :error, "stream_completion_failed", %{
            reason: inspect(reason),
            depth: depth
          })

        fallback_chat_completion(
          reason,
          logical_history,
          prompt_history,
          depth,
          ctx,
          client_opts,
          tools_spec
        )
    end
  end

  defp run_stream(
         stream,
         stream_usage,
         logical_history,
         prompt_history,
         depth,
         ctx,
         client_opts,
         tools_spec
       ) do
    try do
      assistant_msg = StreamAccumulator.consume(stream, &send_stream_token(ctx, &1))

      case finalize_assistant_message(
             assistant_msg,
             logical_history,
             prompt_history,
             depth,
             ctx,
             stream_usage
           ) do
        {:error, :empty_response, updated_ctx} ->
          recover_empty_response(
            logical_history,
            prompt_history,
            depth,
            updated_ctx,
            client_opts
          )

        other ->
          other
      end
    rescue
      error in Protocol.UndefinedError ->
        Logger.warning("[EXECUTOR] Invalid streaming payload. Falling back to chat completion.")

        fallback_chat_completion(
          error,
          logical_history,
          prompt_history,
          depth,
          ctx,
          client_opts,
          tools_spec
        )
    end
  end

  defp fallback_chat_completion(
         reason,
         logical_history,
         prompt_history,
         depth,
         %Ctx{} = ctx,
         client_opts,
         tools_spec
       ) do
    FallbackStrategy.run(
      reason,
      logical_history,
      prompt_history,
      depth,
      ctx,
      client_opts,
      tools_spec,
      prepare_history: &prepare_prompt_history/3,
      finalize: &finalize_assistant_message/7
    )
  end

  defp recover_empty_response(logical_history, prompt_history, depth, %Ctx{} = ctx, client_opts) do
    Logger.warning(
      "[EXECUTOR] Empty streaming response at depth=#{depth}. Retrying lightweight chat completion."
    )

    ctx = Ctx.record_trace(ctx, :policy, "empty_response_recovery", %{depth: depth})

    {base_history, ctx} =
      case EmptyResponseRecoveryPolicy.safe_limit_scale(depth) do
        nil -> {prompt_history, ctx}
        scale -> prepare_prompt_history(logical_history, ctx, safe_limit_scale: scale)
      end

    retry_history = Policy.recover(:empty_response_history, %{history: base_history})

    case ctx.deps.llm_client.chat_completion(retry_history, client_opts) do
      {:ok, assistant_msg, usage} ->
        ctx =
          Ctx.record_trace(ctx, :llm, "chat_completion_invoked", %{
            fallback: false,
            recovery: true
          })

        finalize_assistant_message(
          assistant_msg,
          logical_history,
          retry_history,
          depth,
          ctx,
          usage,
          recovery_attempted?: true
        )

      {:error, reason} ->
        Logger.error("[EXECUTOR] Empty-response recovery failed: #{inspect(reason)}")

        ctx =
          Ctx.record_trace(ctx, :error, "empty_response_recovery_failed", %{
            reason: inspect(reason)
          })

        {:error, :empty_response, ctx}
    end
  end

  @doc false
  def finalize_assistant_message(
        assistant_msg,
        logical_history,
        prompt_history,
        depth,
        %Ctx{} = ctx,
        usage,
        opts \\ []
      ) do
    content = assistant_msg["content"]
    Logger.debug("[EXECUTOR] RAW LLM CONTENT: #{inspect(content)}")

    {clean_content, xml_calls} = Text.extract_xml_tool_calls(content)

    if xml_calls != [] do
      Logger.debug("[EXECUTOR] EXTRACTED XML TOOL CALLS: #{inspect(xml_calls)}")
    end

    final_content =
      if TurnOutcomePolicy.reasoning_only?(clean_content) do
        nil
      else
        clean_content
        |> Text.strip_reasoning()
        |> Text.strip_internal_scaffolding()
      end

    existing_calls = assistant_msg["tool_calls"] || []

    if existing_calls != [] do
      Logger.debug("[EXECUTOR] NATIVE TOOL CALLS: #{inspect(existing_calls)}")
    end

    all_calls = existing_calls ++ xml_calls

    assistant_msg =
      assistant_msg
      |> Map.put("content", if(final_content in ["", nil], do: nil, else: final_content))
      |> Map.put("tool_calls", if(all_calls == [], do: nil, else: all_calls))

    case assistant_msg do
      %{"tool_calls" => tool_calls} when is_list(tool_calls) and tool_calls != [] ->
        normalized_calls = Enum.map(tool_calls, &ToolCall.ensure_type/1)
        assistant_msg = Map.put(assistant_msg, "tool_calls", normalized_calls)

        Logger.info(
          "[EXECUTOR] LLM decided to use tools: #{ToolCall.names_summary(normalized_calls)}"
        )

        {tool_results, ctx} = ToolRunner.execute_batch(normalized_calls, ctx)
        new_logical_history = logical_history ++ [assistant_msg] ++ tool_results

        new_prompt_history =
          prompt_history ++
            [assistant_msg] ++
            tool_results ++ [ToolAnswerPatternPolicy.grounding_message(tool_results)]

        run_loop(new_logical_history, new_prompt_history, depth + 1, ctx)

      %{"content" => final_text} ->
        Logger.info(
          "[EXECUTOR] LLM stream finished. Text length: #{String.length(final_text || "")}"
        )

        tool_messages =
          if depth > 0,
            do: Enum.filter(Enum.reverse(logical_history), &(&1["role"] == "tool")),
            else: []

        resolve_text_outcome(
          final_text,
          assistant_msg,
          logical_history,
          prompt_history,
          tool_messages,
          depth,
          ctx,
          usage,
          opts
        )

      _ ->
        {:error, {:invalid_assistant_message, assistant_msg}, ctx}
    end
  end

  defp resolve_text_outcome(
         final_text,
         assistant_msg,
         logical_history,
         prompt_history,
         tool_messages,
         depth,
         ctx,
         usage,
         opts
       ) do
    case TurnOutcomePolicy.resolve(%{
           final_text: final_text,
           streamed_text: assistant_msg["streamed_text"],
           tool_messages: tool_messages,
           tool_call_count: 0
         }) do
      {:final_text, resolved_content} ->
        updated_msg = Map.put(assistant_msg, "content", resolved_content)
        {:ok, logical_history ++ [updated_msg], resolved_content, usage, ctx}

      {:tool_only, tool_messages} ->
        recovery_attempted? = Keyword.get(opts, :recovery_attempted?, false)

        if EmptyResponseRecoveryPolicy.should_retry_tool_only?(depth, recovery_attempted?) do
          case recover_empty_response(
                 logical_history,
                 prompt_history,
                 depth,
                 ctx,
                 Ctx.client_opts(ctx)
               ) do
            {:ok, _, _, _, _} = ok ->
              ok

            {:error, _reason, err_ctx} ->
              degrade_to_tool_only(assistant_msg, logical_history, tool_messages, usage, err_ctx)
          end
        else
          degrade_to_tool_only(assistant_msg, logical_history, tool_messages, usage, ctx)
        end

      {:error, reason} ->
        {:error, reason, ctx}
    end
  end

  defp degrade_to_tool_only(assistant_msg, logical_history, tool_messages, usage, ctx) do
    final_content = ToolOnlyOutcomeFormatter.format(tool_messages)
    updated_msg = Map.put(assistant_msg, "content", final_content)
    {:ok, logical_history ++ [updated_msg], final_content, usage, ctx}
  end

  defp send_stream_token(%Ctx{session_pid: pid}, token) when is_pid(pid) do
    send(pid, {:agent_stream_token, token})
    :ok
  end

  defp send_stream_token(_ctx, _token), do: :ok

  defp notify_finished(%Ctx{session_pid: pid, ref: nil}, history, content, usage)
       when is_pid(pid),
       do: send(pid, {:executor_finished, history, content, usage})

  defp notify_finished(%Ctx{session_pid: pid, ref: ref}, history, content, usage)
       when is_pid(pid),
       do: send(pid, {:executor_finished, ref, history, content, usage})

  defp notify_finished(_ctx, _history, _content, _usage), do: :ok

  defp notify_failed(%Ctx{session_pid: pid, ref: nil}, reason) when is_pid(pid),
    do: send(pid, {:executor_failed, reason})

  defp notify_failed(%Ctx{session_pid: pid, ref: ref}, reason) when is_pid(pid),
    do: send(pid, {:executor_failed, ref, reason})

  defp notify_failed(_ctx, _reason), do: :ok
end
