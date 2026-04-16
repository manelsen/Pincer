defmodule Pincer.Core.Executor do
  @moduledoc """
  The Unified Executor — a polymath agent that reasons through problems.

  The Executor uses Hexagonal Architecture (Ports and Adapters) to remain decoupled
  from specific tool implementations and LLM providers. Dependencies are injected
  at runtime.
  """

  require Logger
  alias Pincer.Core.AgentPaths
  alias Pincer.Core.ContextOverflowRecovery
  alias Pincer.Core.MemoryRecall
  alias Pincer.Core.Policy
  alias Pincer.Core.PromptAssembly
  alias Pincer.Core.Trace
  alias Pincer.Core.ToolAnswerPatternPolicy
  alias Pincer.Core.ToolOnlyOutcomeFormatter
  alias Pincer.Core.ToolRuntime
  alias Pincer.Core.TurnOutcomePolicy
  alias Pincer.Utils.Text

  @max_recursion_depth Application.compile_env(:pincer, :max_recursion_depth, 100)
  @approval_timeout_ms Application.compile_env(:pincer, :approval_timeout_ms, 600_000)
  @tool_result_max_chars Application.compile_env(:pincer, :tool_result_max_chars, 32_000)
  @max_inline_bytes Application.compile_env(:pincer, :max_inline_bytes, 6_291_456)

  @type executor_dependency :: %{
          llm_client: module(),
          tool_registry: module(),
          file_fetcher: (String.t() -> {:ok, String.t()} | {:error, any()})
        }

  @doc """
  Runs the executor logic for a session.
  Dispatches to the provider and handles recursive tool usage.
  """
  def run(session_pid, session_id, history, opts \\ []) do
    # 1. Resolve Dependencies
    deps = %{
      llm_client: opts[:llm_client] || Pincer.Ports.LLM,
      tool_registry: opts[:tool_registry] || Pincer.Ports.ToolRegistry,
      file_fetcher: opts[:file_fetcher] || (&default_file_fetch/1),
      max_depth:
        opts[:max_depth] ||
          Application.get_env(:pincer, :executor_max_depth, @max_recursion_depth)
    }

    # Store workspace path in process dictionary for easy access in nested calls
    workspace_path = opts[:workspace_path] || AgentPaths.workspace_root(session_id)
    Process.put(:workspace_path, workspace_path)
    Process.put(:executor_deps, deps)
    Process.put(:executor_run_opts, opts)
    Process.put(:executor_trace_session_pid, session_pid)

    if Keyword.get(opts, :trace_events?, false) do
      Process.put(
        :executor_trace,
        Trace.new(session_id, "turn-#{System.unique_integer([:positive])}", %{
          depth_limit: @max_recursion_depth
        })
      )

      emit_trace_step(:checkpoint, "turn_started", %{history_size: length(history)})
    end

    # 2. Setup initial state
    Logger.info("[EXECUTOR] Starting cycle for #{session_id}")

    # 3. Enter recursion loop
    # Initial call uses depth 0
    result =
      run_loop(history, session_id, session_pid, 0, opts[:model_override], deps)

    outcome =
      case result do
        {:ok, final_history, final_content, usage} ->
          emit_trace_step(:checkpoint, "turn_finished", %{
            final_history_size: length(final_history),
            has_usage: not is_nil(usage)
          })

          maybe_emit_trace_snapshot()
          send(session_pid, {:executor_finished, final_history, final_content, usage})
          :ok

        {:error, reason} ->
          emit_trace_step(:error, "turn_failed", %{reason: inspect(reason)})
          maybe_emit_trace_snapshot()
          send(session_pid, {:executor_failed, reason})
          :error
      end

    Process.delete(:workspace_path)
    Process.delete(:executor_deps)
    Process.delete(:executor_run_opts)
    Process.delete(:consecutive_errors)
    Process.delete(:executor_trace)
    Process.delete(:executor_trace_session_pid)

    outcome
  end

  @doc """
  Alternative entry point using `spawn_link` for parallel execution.
  """
  def start(session_pid, session_id, history, opts \\ []) do
    pid =
      spawn_link(fn ->
        run(session_pid, session_id, history, opts)
      end)

    {:ok, pid}
  end

  # --- Multi-modal support helpers ---

  @doc false
  def resolve_attachment_url("telegram://file/" <> _path, token) when token in [nil, ""],
    do: {:error, :telegram_token_missing}

  def resolve_attachment_url("telegram://file/" <> path, token) when is_binary(token),
    do: {:ok, "https://api.telegram.org/file/bot#{token}/#{path}"}

  def resolve_attachment_url(url, _token) when is_binary(url), do: {:ok, url}
  def resolve_attachment_url(_url, _token), do: {:error, :invalid_attachment_url}

  @doc false
  def default_file_fetch(url) do
    with {:ok, resolved_url} <- resolve_attachment_url(url, nil),
         {:ok, response} <-
           Req.get(resolved_url, receive_timeout: 60_000, max_body_length: @max_inline_bytes) do
      case response do
        %{status: 200, body: body} when is_binary(body) ->
          {:ok, Base.encode64(body)}

        %{status: status} ->
          {:error, "HTTP #{status}"}

        _ ->
          {:error, :invalid_response}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_loop(logical_history, session_id, session_pid, depth, model_override, deps) do
    if depth > max_depth(deps) do
      Logger.warning("[EXECUTOR] Depth limit reached (#{depth}/#{max_depth(deps)})")
      send(session_pid, {:executor_failed, {:depth_exceeded, depth}})
      {:error, {:depth_exceeded, depth}}
    else
      updated_model_override = check_messages(model_override)

      if loop_detected?(logical_history) do
        send(session_pid, {:executor_failed, "Tool loop detected. Aborting."})
        {:error, :tool_loop}
      else
        prompt_history =
          if depth == 0 do
            prepare_prompt_history(logical_history, model_override)
          else
            raise "run_loop called with depth > 0 without prompt_history context"
          end

        do_run_loop(
          logical_history,
          prompt_history,
          session_id,
          session_pid,
          depth,
          updated_model_override,
          deps
        )
      end
    end
  end

  # Internal recursive entry point that carries both histories to preserve context
  # without re-pruning (which causes amnesia when tool results are large).
  defp run_loop_recursive(
         logical_history,
         prompt_history,
         session_id,
         session_pid,
         depth,
         model_override,
         deps
       ) do
    if depth > max_depth(deps) do
      Logger.warning("[EXECUTOR] Depth limit reached (#{depth}/#{max_depth(deps)})")
      send(session_pid, {:executor_failed, {:depth_exceeded, depth}})
      {:error, {:depth_exceeded, depth}}
    else
      updated_model_override = check_messages(model_override)

      if loop_detected?(logical_history) do
        send(session_pid, {:executor_failed, "Tool loop detected. Aborting."})
        {:error, :tool_loop}
      else
        do_run_loop(
          logical_history,
          prompt_history,
          session_id,
          session_pid,
          depth,
          updated_model_override,
          deps
        )
      end
    end
  end

  defp check_messages(model_override) do
    receive do
      {:model_changed, provider, model} ->
        Logger.info("[EXECUTOR] Model override updated mid-session: #{provider}:#{model}")
        check_messages(%{provider: provider, model: model})
    after
      0 -> model_override
    end
  end

  defp prepare_prompt_history(history, model_override, opts \\ []) do
    provider_name = get_active_provider(model_override)

    provider_config =
      (Application.get_env(:pincer, :llm_providers, %{}) || %{})
      |> Map.get(provider_name, %{})

    context_strategy = Keyword.get(Process.get(:executor_run_opts, []), :context_strategy)

    prepared_history =
      history
      |> PromptAssembly.prepare(model_override,
        long_term_memory: Process.get(:long_term_memory, ""),
        current_time: DateTime.utc_now() |> DateTime.to_string(),
        workspace_path: Process.get(:workspace_path, File.cwd!()),
        llm_client: Pincer.Ports.LLM,
        storage: Pincer.Ports.Storage,
        memory_recall: MemoryRecall,
        safe_limit_scale: Keyword.get(opts, :safe_limit_scale, 1.0),
        context_strategy: context_strategy
      )
      |> resolve_lazy_attachments(provider_config)

    emit_trace_step(:memory, "prompt_prepared", %{
      messages: length(prepared_history),
      provider: provider_name
    })

    prepared_history
  end

  defp do_run_loop(
         logical_history,
         prompt_history,
         session_id,
         session_pid,
         depth,
         model_override,
         deps
       ) do
    Logger.info("[EXECUTOR] do_run_loop (Depth: #{depth})")

    client_opts =
      case {model_override_field(model_override, :provider),
            model_override_field(model_override, :model)} do
        {provider, model} when is_binary(provider) and is_binary(model) ->
          [provider: provider, model: model]

        _ ->
          []
      end

    client_opts =
      if thinking = model_override_field(model_override, :thinking_level) do
        Keyword.put(client_opts, :thinking_level, thinking)
      else
        client_opts
      end

    tools_spec =
      deps.tool_registry.list_tools()
      |> clean_tools_spec()

    Logger.info(
      "[EXECUTOR] Sending prompt to LLM (STREAMING). History size: #{length(prompt_history)}"
    )

    emit_trace_step(:policy, "llm_request_prepared", %{depth: depth, tools: length(tools_spec)})
    emit_trace_step(:llm, "stream_completion_invoked", %{depth: depth})

    case deps.llm_client.stream_completion(prompt_history, [tools: tools_spec] ++ client_opts) do
      {:ok, stream, stream_usage} ->
        try do
          case handle_stream(
                 stream,
                 logical_history,
                 prompt_history,
                 session_id,
                 session_pid,
                 depth,
                 model_override,
                 deps,
                 stream_usage
               ) do
            {:error, :empty_response} ->
              recover_empty_response(
                logical_history,
                prompt_history,
                session_id,
                session_pid,
                depth,
                model_override,
                deps,
                client_opts
              )

            other ->
              other
          end
        rescue
          error in Protocol.UndefinedError ->
            Logger.warning(
              "[EXECUTOR] Invalid streaming payload. Falling back to chat completion."
            )

            fallback_chat_completion(
              error,
              logical_history,
              prompt_history,
              session_id,
              session_pid,
              depth,
              model_override,
              deps,
              client_opts,
              tools_spec
            )
        end

      {:ok, stream} ->
        try do
          case handle_stream(
                 stream,
                 logical_history,
                 prompt_history,
                 session_id,
                 session_pid,
                 depth,
                 model_override,
                 deps,
                 nil
               ) do
            {:error, :empty_response} ->
              recover_empty_response(
                logical_history,
                prompt_history,
                session_id,
                session_pid,
                depth,
                model_override,
                deps,
                client_opts
              )

            other ->
              other
          end
        rescue
          error in Protocol.UndefinedError ->
            Logger.warning(
              "[EXECUTOR] Invalid streaming payload. Falling back to chat completion."
            )

            fallback_chat_completion(
              error,
              logical_history,
              prompt_history,
              session_id,
              session_pid,
              depth,
              model_override,
              deps,
              client_opts,
              tools_spec
            )
        end

      {:error, {:missing_credentials, _env_key} = cred_error} ->
        Logger.warning("[EXECUTOR] LLM call failed: #{inspect(cred_error)}")
        {:error, cred_error}

      {:error, reason} ->
        Logger.error("[EXECUTOR] LLM streaming failed: #{inspect(reason)}")

        emit_trace_step(:error, "stream_completion_failed", %{
          reason: inspect(reason),
          depth: depth
        })

        fallback_chat_completion(
          reason,
          logical_history,
          prompt_history,
          session_id,
          session_pid,
          depth,
          model_override,
          deps,
          client_opts,
          tools_spec
        )
    end
  end

  defp fallback_chat_completion(
         reason,
         logical_history,
         prompt_history,
         session_id,
         session_pid,
         depth,
         model_override,
         deps,
         client_opts,
         tools_spec
       ) do
    Logger.warning("[EXECUTOR] Falling back to chat completion. Reason: #{inspect(reason)}")
    emit_trace_step(:policy, "fallback_chat_completion", %{reason: inspect(reason)})

    {fallback_history, chat_opts} =
      build_fallback_request(
        reason,
        logical_history,
        prompt_history,
        model_override,
        client_opts,
        tools_spec
      )

    case deps.llm_client.chat_completion(fallback_history, chat_opts) do
      {:ok, assistant_msg, usage} ->
        emit_trace_step(:llm, "chat_completion_invoked", %{fallback: true})

        finalize_assistant_message(
          assistant_msg,
          logical_history,
          prompt_history,
          session_id,
          session_pid,
          depth,
          model_override,
          deps,
          usage
        )

      {:error, reason} ->
        Logger.error("[EXECUTOR] Fallback chat completion failed: #{inspect(reason)}")
        emit_trace_step(:error, "fallback_chat_completion_failed", %{reason: inspect(reason)})
        send(session_pid, {:executor_failed, reason})
        {:error, reason}
    end
  end

  defp recover_empty_response(
         logical_history,
         prompt_history,
         session_id,
         session_pid,
         depth,
         model_override,
         deps,
         client_opts
       ) do
    if true do
      Logger.warning(
        "[EXECUTOR] Empty streaming response at depth=#{depth}. Retrying lightweight chat completion."
      )

      emit_trace_step(:policy, "empty_response_recovery", %{depth: depth})

      # At depth > 0 the prompt_history already contains large tool results that may have
      # overflowed the context. Re-prepare from logical_history with default scale so the
      # history manager can truncate tool messages before appending the recovery prompt.
      base_history =
        if depth == 0 do
          prompt_history
        else
          # Reduce context window aggressively on recovery — large tool results at
          # depth > 0 are the most common cause of empty streaming responses.
          prepare_prompt_history(logical_history, model_override, safe_limit_scale: 0.4)
        end

      retry_history = Policy.recover(:empty_response_history, %{history: base_history})

      case deps.llm_client.chat_completion(retry_history, client_opts) do
        {:ok, assistant_msg, usage} ->
          emit_trace_step(:llm, "chat_completion_invoked", %{fallback: false, recovery: true})

          case finalize_assistant_message(
                 assistant_msg,
                 logical_history,
                 retry_history,
                 session_id,
                 session_pid,
                 depth,
                 model_override,
                 deps,
                 usage
               ) do
            {:error, :empty_response} -> {:error, :empty_response}
            other -> other
          end

        {:error, reason} ->
          Logger.error("[EXECUTOR] Empty-response recovery failed: #{inspect(reason)}")
          emit_trace_step(:error, "empty_response_recovery_failed", %{reason: inspect(reason)})
          {:error, :empty_response}
      end
    end
  end

  defp build_fallback_request(
         reason,
         logical_history,
         prompt_history,
         model_override,
         client_opts,
         tools_spec
       ) do
    case ContextOverflowRecovery.plan(reason, tools_present?: tools_spec != []) do
      {:retry, %{safe_limit_scale: safe_limit_scale, drop_tools?: drop_tools?}} ->
        Logger.warning(
          "[EXECUTOR] Context overflow detected. Rebuilding fallback prompt with scale=#{safe_limit_scale} and drop_tools?=#{drop_tools?}."
        )

        fallback_history =
          prepare_prompt_history(logical_history, model_override,
            safe_limit_scale: safe_limit_scale
          )

        fallback_opts =
          if drop_tools? do
            client_opts
          else
            [tools: tools_spec] ++ client_opts
          end

        {fallback_history, fallback_opts}

      :noop ->
        if tool_calling_unsupported?(reason) do
          Logger.warning(
            "[EXECUTOR] Provider/model does not support tool calling. Retrying fallback chat completion without tools."
          )

          {prompt_history, client_opts}
        else
          {prompt_history, [tools: tools_spec] ++ client_opts}
        end
    end
  end

  defp tool_calling_unsupported?({:http_error, _status, msg}) when is_binary(msg) do
    down = String.downcase(msg)

    String.contains?(down, "tool calling") and
      (String.contains?(down, "not supported") or String.contains?(down, "unsupported"))
  end

  defp tool_calling_unsupported?({:http_error, _status, body, _meta}),
    do: tool_calling_unsupported?({:http_error, nil, body})

  defp tool_calling_unsupported?(_reason), do: false

  defp merge_reasoning_and_content("", ""), do: ""

  defp merge_reasoning_and_content(content, "") when is_binary(content), do: content

  defp merge_reasoning_and_content(content, reasoning)
       when is_binary(content) and is_binary(reasoning) do
    trimmed_reasoning = String.trim(reasoning)
    trimmed_content = String.trim(content)

    cond do
      trimmed_reasoning == "" ->
        content

      trimmed_content != "" ->
        content

      true ->
        ""
    end
  end

  defp reasoning_only_message?(text) when is_binary(text) do
    text
    |> Text.strip_reasoning()
    |> to_string()
    |> String.trim() == ""
  end

  defp reasoning_only_message?(_text), do: false

  defp post_tool_grounding_message(tool_results) do
    extra = ToolAnswerPatternPolicy.build(tool_results)

    %{
      "role" => "user",
      "content" =>
        if(
          extra == "",
          do:
            "[system] Ground yourself strictly in the tool outputs above. Do not invent files, results, success, or side effects. If a tool failed, found nothing, or returned limited data, say that plainly.",
          else:
            "[system] Ground yourself strictly in the tool outputs above. Do not invent files, results, success, or side effects. If a tool failed, found nothing, or returned limited data, say that plainly.\n\n#{extra}"
        )
    }
  end

  defp handle_stream(
         stream,
         logical_history,
         prompt_history,
         session_id,
         session_pid,
         depth,
         model_override,
         deps,
         stream_usage
       ) do
    # State: {full_content, full_reasoning, tool_calls_map, stream_buffer, is_filtering?}
    {full_content, full_reasoning, full_tool_calls, buffer, filtering?} =
      Enum.reduce(stream, {"", "", %{}, "", false}, fn chunk,
                                                       {acc_text, acc_reasoning, acc_tools,
                                                        buffer, filtering?} ->
        process_chunk(
          chunk,
          acc_text,
          acc_reasoning,
          acc_tools,
          buffer,
          filtering?,
          session_pid
        )
      end)

    full_content =
      flush_stream_buffer(full_content, buffer, filtering?)

    tool_calls_list = format_tool_calls(full_tool_calls)
    content = merge_reasoning_and_content(full_content, full_reasoning)

    assistant_msg = %{
      "role" => "assistant",
      "content" => if(content == "", do: nil, else: content),
      "tool_calls" => tool_calls_list,
      "streamed_text" =>
        content
        |> Text.strip_reasoning()
        |> Text.strip_internal_scaffolding()
    }

    finalize_assistant_message(
      assistant_msg,
      logical_history,
      prompt_history,
      session_id,
      session_pid,
      depth,
      model_override,
      deps,
      stream_usage
    )
  end

  defp process_chunk(chunk, acc_text, acc_reasoning, acc_tools, buffer, filtering?, session_pid) do
    case chunk do
      %{"choices" => [%{"delta" => delta}]} ->
        tool_deltas = delta["tool_calls"]
        content = delta["content"] || ""
        reasoning = delta["reasoning"] || delta["reasoning_content"] || ""

        {new_text, new_buffer, new_filtering} =
          append_content_token(content, acc_text, buffer, filtering?, session_pid)

        new_reasoning = append_reasoning(reasoning, acc_reasoning)

        new_tools = merge_tool_deltas_if_present(tool_deltas, acc_tools)

        {new_text, new_reasoning, new_tools, new_buffer, new_filtering}

      _ ->
        {acc_text, acc_reasoning, acc_tools, buffer, filtering?}
    end
  end

  defp append_content_token(content, acc_text, buffer, filtering?, session_pid)
       when is_binary(content) and content != "" do
    handle_content_token(content, acc_text, buffer, filtering?, session_pid)
  end

  defp append_content_token(_content, acc_text, buffer, filtering?, _session_pid),
    do: {acc_text, buffer, filtering?}

  defp append_reasoning(reasoning, acc_reasoning)
       when is_binary(reasoning) and reasoning != "",
       do: acc_reasoning <> reasoning

  defp append_reasoning(_reasoning, acc_reasoning), do: acc_reasoning

  defp merge_tool_deltas_if_present(nil, acc_tools), do: acc_tools

  defp merge_tool_deltas_if_present(tool_deltas, acc_tools),
    do: merge_tool_deltas(acc_tools, tool_deltas)

  defp handle_content_token(token, acc_text, buffer, filtering?, session_pid) do
    new_buffer = buffer <> token

    # Tags that should trigger filtering during stream
    tags = [
      "<function",
      "<parameter",
      "<tool_call",
      "<think",
      "<thought",
      "<thinking",
      "<antthinking",
      "<relevant-memories",
      "<relevant_memories",
      "<final"
    ]

    should_start_filtering = not filtering? and Enum.any?(tags, &String.contains?(new_buffer, &1))

    # Closing tags that definitively end a tool-call or thinking block.
    # We only stop filtering when we see one of these — NOT on every ">", which
    # would prematurely resume emission mid-tag (e.g. on <arg_key>, <parameter>, etc.)
    closing_tags = [
      "</function>",
      "</tool_call>",
      "</think>",
      "</thought>",
      "</thinking>",
      "</antthinking>",
      "</final>",
      "</relevant-memories>",
      "</relevant_memories>"
    ]

    cond do
      # 1. Start filtering if we see the beginning of any suspicious tag
      should_start_filtering ->
        # Find which tag triggered it to extract text before it
        trigger_tag = Enum.find(tags, &String.contains?(new_buffer, &1))
        [text_before | _] = String.split(new_buffer, trigger_tag, parts: 2)
        if text_before != "", do: send(session_pid, {:agent_stream_token, text_before})
        {acc_text <> text_before, new_buffer, true}

      # 2. Stop filtering only when we see a proper closing tag.
      # Using specific closers avoids prematurely stopping on ">" inside nested
      # tags like <arg_key>, <parameter name="...">, etc.
      filtering? and Enum.any?(closing_tags, &String.contains?(new_buffer, &1)) ->
        # Clear the buffer so the closing tag doesn't trigger case 1 on the next token.
        {acc_text <> token, "", false}

      # 3. Currently filtering: keep buffering, send nothing to user
      filtering? ->
        {acc_text <> token, new_buffer, true}

      # 4. Normal flow: send token directly
      true ->
        send(session_pid, {:agent_stream_token, token})
        {acc_text <> token, "", false}
    end
  end

  defp flush_stream_buffer(acc_text, "", _filtering?), do: acc_text

  defp flush_stream_buffer(acc_text, buffer, true) when is_binary(buffer) do
    visible_tail =
      buffer
      |> Text.strip_reasoning()
      |> Text.strip_internal_scaffolding()

    case String.trim(visible_tail) do
      "" -> acc_text
      _ -> acc_text <> visible_tail
    end
  end

  defp flush_stream_buffer(acc_text, _buffer, false), do: acc_text

  defp finalize_assistant_message(
         assistant_msg,
         logical_history,
         prompt_history,
         session_id,
         session_pid,
         depth,
         model_override,
         deps,
         usage
       ) do
    content = assistant_msg["content"]

    # DEBUG: Log exact LLM output
    Logger.debug("[EXECUTOR] RAW LLM CONTENT: #{inspect(content)}")

    # 1. OpenClaw-inspired: Intercept XML tools and Strip scaffolding
    {clean_content, xml_calls} = Text.extract_xml_tool_calls(content)

    if xml_calls != [] do
      Logger.debug("[EXECUTOR] EXTRACTED XML TOOL CALLS: #{inspect(xml_calls)}")
    end

    final_content =
      if reasoning_only_message?(clean_content) do
        nil
      else
        clean_content
        |> Text.strip_reasoning()
        |> Text.strip_internal_scaffolding()
      end

    # Reconstruct message with cleaned content and merged tool calls
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
        normalized_tool_calls = Enum.map(tool_calls, &ensure_tool_call_type/1)
        assistant_msg = Map.put(assistant_msg, "tool_calls", normalized_tool_calls)

        tool_names =
          normalized_tool_calls
          |> Enum.map(&tool_call_name/1)
          |> Enum.reject(&is_nil_or_blank/1)
          |> Enum.join(", ")

        tool_names = if tool_names == "", do: "unknown_tool", else: tool_names
        Logger.info("[EXECUTOR] LLM decided to use tools: #{tool_names}")

        tool_descriptions =
          Enum.map(normalized_tool_calls, &tool_call_description/1)

        send(session_pid, {:sme_tool_use, tool_descriptions})

        # Planning step: If multiple tools, notify user and execute in parallel
        tool_results =
          if length(normalized_tool_calls) > 1 do
            tool_names =
              normalized_tool_calls
              |> Enum.map(&tool_call_name/1)
              |> Enum.reject(&is_nil_or_blank/1)
              |> Enum.join(", ")

            send(
              session_pid,
              {:executor_status,
               "⚡ **Orquestração Paralela**: Executando #{length(normalized_tool_calls)} tarefas simultâneas (#{tool_names})."}
            )

            # Capture context for parallel tasks
            parent_context = %{
              workspace_path: Process.get(:workspace_path),
              executor_deps: Process.get(:executor_deps),
              executor_trace: Process.get(:executor_trace),
              executor_trace_session_pid: Process.get(:executor_trace_session_pid),
              executor_run_opts: Process.get(:executor_run_opts)
            }

            normalized_tool_calls
            |> Task.async_stream(
              fn call ->
                # Restore context in the new process
                Process.put(:workspace_path, parent_context.workspace_path)
                Process.put(:executor_deps, parent_context.executor_deps)
                Process.put(:executor_trace, parent_context.executor_trace)

                Process.put(
                  :executor_trace_session_pid,
                  parent_context.executor_trace_session_pid
                )

                Process.put(:executor_run_opts, parent_context.executor_run_opts)

                execute_tool_via_registry(call, session_pid, session_id, deps.tool_registry)
              end,
              max_concurrency: 10,
              timeout: @approval_timeout_ms
            )
            |> Enum.map(fn
              {:ok, result} ->
                result

              {:error, reason} ->
                %{"role" => "tool", "content" => "Parallel execution error: #{inspect(reason)}"}
            end)
          else
            Enum.map(normalized_tool_calls, fn call ->
              execute_tool_via_registry(call, session_pid, session_id, deps.tool_registry)
            end)
          end

        # Update both histories for the next turn
        new_logical_history = logical_history ++ [assistant_msg] ++ tool_results

        new_prompt_history =
          prompt_history ++
            [assistant_msg] ++ tool_results ++ [post_tool_grounding_message(tool_results)]

        run_loop_recursive(
          new_logical_history,
          new_prompt_history,
          session_id,
          session_pid,
          depth + 1,
          model_override,
          deps
        )

      %{"content" => content} ->
        Logger.info(
          "[EXECUTOR] LLM stream finished. Text length: #{String.length(content || "")}"
        )

        tool_messages = Enum.filter(Enum.reverse(logical_history), &(&1["role"] == "tool"))

        case TurnOutcomePolicy.resolve(%{
               final_text: content,
               streamed_text: assistant_msg["streamed_text"],
               tool_messages: if(depth > 0, do: tool_messages, else: []),
               tool_call_count: 0
             }) do
          {:final_text, final_content} ->
            assistant_msg = Map.put(assistant_msg, "content", final_content)

            # IMPORTANT: Return clean logical history to session
            {:ok, logical_history ++ [assistant_msg], final_content, usage}

          {:tool_only, tool_messages} ->
            final_content = ToolOnlyOutcomeFormatter.format(tool_messages)
            assistant_msg = Map.put(assistant_msg, "content", final_content)
            {:ok, logical_history ++ [assistant_msg], final_content, usage}

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        {:error, {:invalid_assistant_message, assistant_msg}}
    end
  end

  defp merge_tool_deltas(acc, deltas) when is_list(deltas) do
    Enum.reduce(deltas, acc, fn delta, inner_acc ->
      index = read_map_field(delta, "index", :index)

      existing =
        Map.get(inner_acc, index, %{
          "index" => index,
          "id" => nil,
          "type" => "function",
          "function" => %{"name" => "", "arguments" => ""}
        })

      function_delta = read_map_field(delta, "function", :function)

      type_delta =
        delta
        |> read_map_field("type", :type)
        |> normalize_binary()

      name_delta =
        function_delta
        |> read_map_field("name", :name)
        |> normalize_binary()

      updated = Map.put(existing, "id", read_map_field(delta, "id", :id) || existing["id"])
      updated = Map.put(updated, "type", type_delta || existing["type"] || "function")

      updated =
        put_in(updated, ["function", "name"], (existing["function"]["name"] || "") <> name_delta)

      args_delta =
        function_delta
        |> read_map_field("arguments", :arguments)
        |> normalize_arguments_fragment()

      updated =
        put_in(
          updated,
          ["function", "arguments"],
          (existing["function"]["arguments"] || "") <> args_delta
        )

      Map.put(inner_acc, index, updated)
    end)
  end

  defp merge_tool_deltas(acc, _deltas), do: acc

  defp execute_tool_via_registry(tool_call, session_pid, session_id, registry)
       when is_map(tool_call) do
    {call_id, name, raw_arguments} = normalize_tool_call(tool_call)
    Logger.info("[TOOL] Executing #{name}")

    tool_class =
      case ToolRuntime.classify(name) do
        {:ok, class} -> class
        _ -> :privileged
      end

    emit_trace_step(:tool, "tool_invoked", %{tool: name, tool_call_id: call_id, class: tool_class})

    args = parse_tool_arguments(raw_arguments)

    workspace_path = Process.get(:workspace_path)

    context = %{
      "session_id" => session_id,
      "workspace_path" => workspace_path,
      session_id: session_id,
      workspace_path: workspace_path
    }

    result =
      try do
        case ToolRuntime.execute(name, args, context, registry, approval_granted: false) do
          {:ok, c, _meta} ->
            Process.put(:consecutive_errors, 0)

            audit =
              Policy.guard!(:tool_audit_event, %{tool: name, class: tool_class, status: :ok})

            emit_trace_step(:tool, "tool_audit", audit)
            c

          {:error, {:approval_required, approval_data}, _meta} when is_map(approval_data) ->
            Process.put(:consecutive_errors, 0)

            audit =
              Policy.guard!(:tool_audit_event, %{
                tool: name,
                class: tool_class,
                status: :approval_required
              })

            emit_trace_step(:tool, "tool_audit", audit)
            handle_approval(call_id, approval_data, session_pid, session_id, registry)

          {:error, {:approval_required, cmd}, _meta} ->
            Process.put(:consecutive_errors, 0)

            audit =
              Policy.guard!(:tool_audit_event, %{
                tool: name,
                class: tool_class,
                status: :approval_required
              })

            emit_trace_step(:tool, "tool_audit", audit)

            handle_approval(
              call_id,
              %{tool: name, command: cmd, class: tool_class},
              session_pid,
              session_id,
              registry
            )

          {:error, :timeout, _meta} ->
            errors = Process.get(:consecutive_errors, 0) + 1
            Process.put(:consecutive_errors, errors)

            audit =
              Policy.guard!(:tool_audit_event, %{tool: name, class: tool_class, status: :timeout})

            emit_trace_step(:tool, "tool_audit", audit)
            "Error: tool '#{name}' timed out and was cancelled."

          {:error, r, _meta} ->
            errors = Process.get(:consecutive_errors, 0) + 1
            Process.put(:consecutive_errors, errors)

            # Auto-capture error if it repeats
            if errors >= 3 do
              Logger.warning(
                "[SELF-IMPROVEMENT] Consecutive tool error detected. Capturing to Graph."
              )

              Pincer.Ports.Storage.save_tool_error(name, args, inspect(r))
            end

            audit =
              Policy.guard!(:tool_audit_event, %{tool: name, class: tool_class, status: :error})

            emit_trace_step(:tool, "tool_audit", audit)
            "Error: #{inspect(r)}"
        end
      rescue
        e ->
          Logger.error("[TOOL] #{name} raised an exception: #{Exception.message(e)}")
          "Error: tool '#{name}' raised an unexpected exception — #{Exception.message(e)}"
      end

    maybe_send_markdown_artifacts(session_pid)

    content =
      case result do
        parts when is_list(parts) ->
          # Multimodal tool result (e.g. screenshot_inline): pass parts directly to the LLM.
          parts

        _ ->
          text = to_string(result)

          if String.length(text) > @tool_result_max_chars do
            truncated = String.slice(text, 0, @tool_result_max_chars)
            truncated <> "\n[...resultado truncado — #{String.length(text)} chars originais]"
          else
            text
          end
      end

    # DEBUG: Log exact tool output
    Logger.debug("[EXECUTOR] TOOL RESULT (#{name}): #{inspect(content)}")

    emit_trace_step(:tool, "tool_result", %{
      tool: name,
      summary: ToolRuntime.sanitize_summary(name, content)
    })

    %{"role" => "tool", "tool_call_id" => call_id, "name" => name, "content" => content}
  end

  defp execute_tool_via_registry(_invalid_call, _session_pid, _session_id, _registry) do
    emit_trace_step(:error, "tool_invalid_call", %{})

    %{
      "role" => "tool",
      "tool_call_id" => "tool_call_invalid",
      "name" => "unknown_tool",
      "content" => "Error: invalid tool call payload."
    }
  end

  defp handle_approval(call_id, approval_data, _session_pid, session_id, registry) do
    command = Map.get(approval_data, :command) || Map.get(approval_data, "command") || ""
    tool_name = Map.get(approval_data, :tool) || Map.get(approval_data, "tool") || "safe_shell"

    tool_args =
      Map.get(approval_data, :args) || Map.get(approval_data, "args") || %{"command" => command}

    tool_class = Map.get(approval_data, :class) || Map.get(approval_data, "class") || :privileged

    approval_prompt = build_approval_prompt(command, tool_name)

    Logger.warning("[EXECUTOR] Waiting for approval for: #{approval_prompt}")

    Pincer.Infra.PubSub.broadcast(
      "session:#{session_id}",
      {:approval_required, call_id, approval_prompt}
    )

    # We wait synchronously here but the session GenServer remains responsive
    # to the user input because this is running in a spawned task.
    receive do
      {:tool_approval_result, ^call_id, :approved} ->
        Logger.info("[EXECUTOR] Command approved: #{command}")

        audit =
          Policy.guard!(:tool_audit_event, %{
            tool: tool_name,
            class: tool_class,
            status: :approved
          })

        emit_trace_step(:tool, "tool_audit", audit)

        case ToolRuntime.execute(tool_name, tool_args, %{"session_id" => session_id}, registry,
               approval_granted: true,
               class: tool_class
             ) do
          {:ok, result, _meta} ->
            result

          {:error, reason, _meta} ->
            "Error: #{inspect(reason)}"
        end

      {:tool_approval_result, ^call_id, :rejected} ->
        Logger.info("[EXECUTOR] Command rejected: #{command}")

        audit =
          Policy.guard!(:tool_audit_event, %{tool: tool_name, class: tool_class, status: :denied})

        emit_trace_step(:tool, "tool_audit", audit)

        recovery =
          Policy.recover(:tool_approval_denied, %{
            tool: tool_name,
            class: tool_class,
            reason: :user_denied
          })

        "Approval denied for #{tool_name}. Recovery: #{inspect(recovery)}"
    after
      @approval_timeout_ms ->
        Logger.warning("[EXECUTOR] Approval timeout for: #{command}")
        "Error: Command timed out waiting for approval."
    end
  end

  defp maybe_send_markdown_artifacts(session_pid) do
    workspace_path = Process.get(:workspace_path)

    if workspace_path do
      case File.ls(workspace_path) do
        {:ok, files} ->
          # List files ending in .md
          files
          |> Enum.filter(&String.ends_with?(&1, ".md"))
          |> Enum.each(fn file ->
            # Only send if it was modified recently (e.g. in this cycle)
            # This is a bit naive, but for now we'll just check if it exists
            # We skip BOOTSTRAP.md as it's system-internal
            if file != "BOOTSTRAP.md" do
              path = Path.join(workspace_path, file)

              case File.read(path) do
                {:ok, content} ->
                  msg = "📝 **Artefato Atualizado**: `#{file}`\n\n#{truncate_markdown(content)}"
                  send(session_pid, {:executor_status, msg})

                _ ->
                  :ok
              end
            end
          end)

        _ ->
          :ok
      end
    end
  end

  defp truncate_markdown(content) do
    if String.length(content) > 1000 do
      String.slice(content, 0, 1000) <> "\n\n[...conteúdo truncado]"
    else
      content
    end
  end

  defp maybe_emit_trace_snapshot do
    case Process.get(:executor_trace) do
      nil ->
        :ok

      trace ->
        case Process.get(:executor_trace_session_pid) do
          pid when is_pid(pid) ->
            send(pid, {:executor_trace, Trace.to_checkpoint_metadata(trace)})

          _ ->
            :ok
        end
    end
  end

  defp emit_trace_step(kind, name, details)
       when is_atom(kind) and is_binary(name) and is_map(details) do
    case Process.get(:executor_trace) do
      nil ->
        :ok

      trace ->
        updated = Trace.add_step(trace, kind, name, details)
        Process.put(:executor_trace, updated)

        case Process.get(:executor_trace_session_pid) do
          pid when is_pid(pid) -> send(pid, {:executor_trace_step, kind, name, details})
          _ -> :ok
        end
    end
  end

  defp build_approval_prompt(command, _tool_name)
       when is_binary(command) and command != "",
       do: command

  defp build_approval_prompt(_command, tool_name),
    do: "#{tool_name} (privileged tool requires approval)"

  defp format_tool_calls(full_tool_calls) when map_size(full_tool_calls) == 0, do: nil

  defp format_tool_calls(full_tool_calls) do
    full_tool_calls
    |> Map.values()
    |> Enum.sort_by(& &1["index"])
    |> Enum.map(fn map -> Map.delete(map, "index") end)
  end

  defp normalize_tool_call(%{"id" => id, "function" => %{"name" => name, "arguments" => args}}),
    do: {id, name, args}

  defp normalize_tool_call(%{id: id, function: %{name: name, arguments: args}}),
    do: {id, name, args}

  defp normalize_tool_call(call) do
    id = call["id"] || call[:id] || "call_unknown"
    f = call["function"] || call[:function] || %{}
    name = f["name"] || f[:name] || "unknown"
    args = f["arguments"] || f[:arguments] || "{}"
    {id, name, args}
  end

  defp parse_tool_arguments(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, args} ->
        args

      {:error, reason} ->
        salvaged = salvage_tool_arguments(json)

        Logger.warning(
          "[EXECUTOR] Malformed tool arguments JSON#{if(salvaged == %{}, do: " (falling back to empty args)", else: " (salvaged partial args)")}: #{inspect(reason)} — raw: #{inspect(json)}"
        )

        salvaged
    end
  end

  defp parse_tool_arguments(args) when is_map(args), do: args
  defp parse_tool_arguments(_), do: %{}

  defp salvage_tool_arguments(json) when is_binary(json) do
    trimmed = String.trim(json)

    if String.starts_with?(trimmed, "{") do
      case parse_loose_json_object(trimmed) do
        {:ok, args} when map_size(args) > 0 -> args
        _ -> %{}
      end
    else
      %{}
    end
  end

  defp parse_loose_json_object("{" <> rest), do: parse_loose_json_members(rest, %{})
  defp parse_loose_json_object(_), do: :error

  defp parse_loose_json_members(binary, acc) do
    binary = String.trim_leading(binary)

    cond do
      binary == "" ->
        {:ok, acc}

      String.starts_with?(binary, "}") ->
        {:ok, acc}

      true ->
        with {:ok, key, after_key} <- parse_loose_json_string(binary),
             after_key <- String.trim_leading(after_key),
             true <- String.starts_with?(after_key, ":"),
             {:ok, value, after_value} <-
               parse_loose_json_value(String.trim_leading(String.slice(after_key, 1..-1//1))),
             {:ok, next} <- parse_loose_json_separator(after_value) do
          parse_loose_json_members(next, Map.put(acc, key, value))
        else
          _ -> if(map_size(acc) > 0, do: {:ok, acc}, else: :error)
        end
    end
  end

  defp parse_loose_json_separator(binary) do
    binary = String.trim_leading(binary)

    cond do
      binary == "" -> {:ok, ""}
      String.starts_with?(binary, ",") -> {:ok, String.slice(binary, 1..-1//1)}
      String.starts_with?(binary, "}") -> {:ok, ""}
      true -> :error
    end
  end

  defp parse_loose_json_value("\"" <> _ = binary), do: parse_loose_json_string(binary)

  defp parse_loose_json_value(binary) do
    literal =
      binary
      |> String.split(~r/\s*(?:,|})/, parts: 2, trim: false)
      |> List.first()
      |> to_string()
      |> String.trim()

    cond do
      literal == "" ->
        :error

      literal == "true" ->
        {:ok, true, String.slice(binary, byte_size(literal)..-1//1)}

      literal == "false" ->
        {:ok, false, String.slice(binary, byte_size(literal)..-1//1)}

      literal == "null" ->
        {:ok, nil, String.slice(binary, byte_size(literal)..-1//1)}

      Regex.match?(~r/^-?\d+$/, literal) ->
        {:ok, String.to_integer(literal), String.slice(binary, byte_size(literal)..-1//1)}

      Regex.match?(~r/^-?\d+\.\d+$/, literal) ->
        {:ok, String.to_float(literal), String.slice(binary, byte_size(literal)..-1//1)}

      true ->
        :error
    end
  end

  defp parse_loose_json_string("\"" <> rest), do: parse_loose_json_string_chars(rest, [], false)
  defp parse_loose_json_string(_), do: :error

  defp parse_loose_json_string_chars(<<>>, acc, _escaped?),
    do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary(), ""}

  defp parse_loose_json_string_chars(<<"\"", rest::binary>>, acc, false),
    do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp parse_loose_json_string_chars(<<"\\", rest::binary>>, acc, false),
    do: parse_loose_json_string_escape(rest, acc)

  defp parse_loose_json_string_chars(<<char::utf8, rest::binary>>, acc, _escaped?),
    do: parse_loose_json_string_chars(rest, [<<char::utf8>> | acc], false)

  defp parse_loose_json_string_escape(<<>>, acc),
    do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary(), ""}

  defp parse_loose_json_string_escape(<<"\"", rest::binary>>, acc),
    do: parse_loose_json_string_chars(rest, ["\"" | acc], false)

  defp parse_loose_json_string_escape(<<"\\", rest::binary>>, acc),
    do: parse_loose_json_string_chars(rest, ["\\" | acc], false)

  defp parse_loose_json_string_escape(<<"/", rest::binary>>, acc),
    do: parse_loose_json_string_chars(rest, ["/" | acc], false)

  defp parse_loose_json_string_escape(<<"b", rest::binary>>, acc),
    do: parse_loose_json_string_chars(rest, ["\b" | acc], false)

  defp parse_loose_json_string_escape(<<"f", rest::binary>>, acc),
    do: parse_loose_json_string_chars(rest, ["\f" | acc], false)

  defp parse_loose_json_string_escape(<<"n", rest::binary>>, acc),
    do: parse_loose_json_string_chars(rest, ["\n" | acc], false)

  defp parse_loose_json_string_escape(<<"r", rest::binary>>, acc),
    do: parse_loose_json_string_chars(rest, ["\r" | acc], false)

  defp parse_loose_json_string_escape(<<"t", rest::binary>>, acc),
    do: parse_loose_json_string_chars(rest, ["\t" | acc], false)

  defp parse_loose_json_string_escape(<<"u", hex::binary-size(4), rest::binary>>, acc) do
    case Integer.parse(hex, 16) do
      {codepoint, ""} -> parse_loose_json_string_chars(rest, [<<codepoint::utf8>> | acc], false)
      _ -> parse_loose_json_string_chars(rest, ["u", hex | acc], false)
    end
  end

  defp parse_loose_json_string_escape(<<char::utf8, rest::binary>>, acc),
    do: parse_loose_json_string_chars(rest, [<<char::utf8>> | acc], false)

  defp ensure_tool_call_type(call) do
    call |> Map.put_new("type", "function")
  end

  defp max_depth(deps) do
    Map.get(deps, :max_depth, @max_recursion_depth)
  end

  defp loop_detected?(history) do
    identical_sequence_loop?(history) or high_frequency_loop?(history)
  end

  # Check 1: 3+ consecutive assistant messages with identical tool_call sets (name + args).
  defp identical_sequence_loop?(history) do
    # Take the last 10 messages, but only look at the assistant ones with tool calls
    assistant_msgs =
      history
      |> Enum.take(-10)
      |> Enum.filter(fn
        %{"role" => "assistant", "tool_calls" => calls} ->
          is_list(calls) and length(calls) > 0

        _ ->
          false
      end)

    if length(assistant_msgs) >= 3 do
      # Compare the fingerprints of the last 3 assistant messages with tool calls
      fingerprints =
        assistant_msgs
        |> Enum.take(-3)
        |> Enum.map(fn %{"tool_calls" => calls} ->
          calls
          |> Enum.map(fn call ->
            {get_in(call, ["function", "name"]), get_in(call, ["function", "arguments"])}
          end)
          |> Enum.sort()
        end)

      # If all 3 are identical, we are in a loop
      case fingerprints do
        [f1, f2, f3] -> f1 == f2 and f2 == f3
        _ -> false
      end
    else
      false
    end
  end

  # Check 2: any single (name+args) pair appearing 10+ times in the last 15 assistant turns.
  # Using the pair instead of name alone avoids false positives when the same tool is legitimately
  # called with different arguments (e.g., debugging by trying different commands).
  defp high_frequency_loop?(history) do
    recent_pairs =
      history
      |> Enum.take(-15)
      |> Enum.flat_map(fn
        %{"tool_calls" => calls} when not is_nil(calls) ->
          Enum.map(calls, fn tc ->
            {get_in(tc, ["function", "name"]), get_in(tc, ["function", "arguments"])}
          end)

        _ ->
          []
      end)
      |> Enum.reject(fn {name, _} -> is_nil(name) end)

    Enum.any?(
      Enum.frequencies(recent_pairs),
      fn {_pair, count} -> count >= 10 end
    )
  end

  defp tool_call_name(tool_call) when is_map(tool_call) do
    get_in(tool_call, ["function", "name"]) || get_in(tool_call, [:function, :name])
  end

  defp tool_call_name(_), do: nil

  defp tool_call_description(tool_call) when is_map(tool_call) do
    name = tool_call_name(tool_call) || "unknown"

    raw_args = get_in(tool_call, ["function", "arguments"]) || %{}

    args =
      cond do
        is_map(raw_args) -> raw_args
        is_binary(raw_args) -> Jason.decode!(raw_args)
        true -> %{}
      end

    summarize_tool_call(name, args)
  rescue
    _ -> tool_call_name(tool_call) || "unknown"
  end

  defp tool_call_description(_), do: "unknown"

  defp summarize_tool_call("run_command", %{"command" => cmd}),
    do: "run_command: #{truncate_desc(cmd, 70)}"

  defp summarize_tool_call("file_system", %{"action" => action, "path" => path}),
    do: "file_system #{action}: #{truncate_desc(path, 60)}"

  defp summarize_tool_call("file_system", %{"action" => action}),
    do: "file_system: #{action}"

  defp summarize_tool_call("read_file", %{"path" => path}),
    do: "read_file: #{truncate_desc(path, 70)}"

  defp summarize_tool_call("write_file", %{"path" => path}),
    do: "write_file: #{truncate_desc(path, 70)}"

  defp summarize_tool_call(name, args) when map_size(args) == 0, do: name

  defp summarize_tool_call(name, args) do
    first_val =
      args
      |> Map.values()
      |> List.first()
      |> to_string()
      |> truncate_desc(60)

    "#{name}: #{first_val}"
  end

  defp truncate_desc(str, max) when is_binary(str) do
    if String.length(str) > max, do: String.slice(str, 0, max) <> "…", else: str
  end

  defp truncate_desc(val, max), do: val |> to_string() |> truncate_desc(max)

  defp get_active_provider(%{provider: provider}) when is_binary(provider), do: provider
  defp get_active_provider(%{"provider" => provider}) when is_binary(provider), do: provider

  defp get_active_provider(nil) do
    Application.get_env(:pincer, :default_llm_provider) ||
      Pincer.Infra.Config.get(:llm)["provider"] ||
      "openrouter"
  end

  defp get_active_provider(_model_override) do
    Application.get_env(:pincer, :default_llm_provider) ||
      Pincer.Infra.Config.get(:llm)["provider"] ||
      "openrouter"
  end

  defp model_override_field(nil, _key), do: nil

  defp model_override_field(model_override, key) when is_map(model_override) do
    Map.get(model_override, key) || Map.get(model_override, Atom.to_string(key))
  end

  defp model_override_field(_model_override, _key), do: nil

  defp clean_tools_spec(tools) when is_list(tools) do
    Enum.map(tools, &clean_tool_map/1)
  end

  defp clean_tools_spec(other), do: other

  defp clean_tool_map(tool) when is_map(tool) do
    tool
    |> Enum.reject(fn {k, _v} ->
      k_str = to_string(k)
      String.starts_with?(k_str, "_")
    end)
    |> Enum.map(fn {k, v} -> {k, clean_tool_value(v)} end)
    |> Map.new()
  end

  defp clean_tool_map(other), do: other

  defp clean_tool_value(v) when is_map(v), do: clean_tool_map(v)
  defp clean_tool_value(v) when is_list(v), do: Enum.map(v, &clean_tool_value/1)
  defp clean_tool_value(v), do: v

  defp resolve_lazy_attachments(history, provider) do
    Enum.map(history, &resolve_msg_attachments(&1, provider))
  end

  defp resolve_msg_attachments(%{"content" => content} = msg, provider) when is_list(content) do
    Map.put(msg, "content", Enum.map(content, &resolve_attachment_ref(&1, provider)))
  end

  defp resolve_msg_attachments(msg, _provider), do: msg

  defp resolve_attachment_ref(%{"type" => "attachment_ref"} = ref, provider) do
    url = ref["url"] || ""
    mime = ref["mime_type"] || "application/octet-stream"
    filename = ref["filename"] || "attachment"
    size = ref["size"] || 0

    cond do
      size > @max_inline_bytes ->
        %{
          "type" => "text",
          "text" => "[#{filename} exceeds inline limit (#{div(size, 1_048_576)} MB) — not loaded]"
        }

      String.starts_with?(mime, "text/") ->
        case download_as_base64(url) do
          {:ok, b64} ->
            text = b64 |> Base.decode64!() |> String.slice(0, 32_768)
            %{"type" => "text", "text" => "Content of #{filename}:\n#{text}"}

          {:error, reason} ->
            %{"type" => "text", "text" => "[Failed to download #{filename}: #{inspect(reason)}]"}
        end

      provider[:supports_files] ->
        case download_as_base64(url) do
          {:ok, b64} ->
            %{"type" => "inline_data", "mime_type" => mime, "data" => b64}

          {:error, reason} ->
            %{"type" => "text", "text" => "[Failed to download #{filename}: #{inspect(reason)}]"}
        end

      true ->
        %{
          "type" => "text",
          "text" => "[Provider does not support attachments: #{filename} (#{mime})]"
        }
    end
  end

  defp resolve_attachment_ref(part, _provider), do: part

  defp download_as_base64(url) do
    fetcher =
      case Process.get(:executor_deps) do
        %{file_fetcher: f} -> f
        _ -> &Pincer.Core.Executor.default_file_fetch/1
      end

    fetcher.(url)
  end

  defp read_map_field(map, string_key, atom_key) do
    Map.get(map, string_key) || Map.get(map, atom_key)
  end

  defp normalize_arguments_fragment(nil), do: ""
  defp normalize_arguments_fragment(bin) when is_binary(bin), do: bin
  defp normalize_arguments_fragment(map) when is_map(map), do: Jason.encode!(map)
  defp normalize_arguments_fragment(_), do: ""

  defp normalize_binary(nil), do: nil
  defp normalize_binary(bin) when is_binary(bin), do: bin

  defp normalize_binary(atom) when is_atom(atom),
    do: atom |> Atom.to_string() |> normalize_binary()

  defp normalize_binary(other), do: other |> Kernel.inspect() |> normalize_binary()

  defp is_nil_or_blank(nil), do: true
  defp is_nil_or_blank(value) when is_binary(value), do: String.trim(value) == ""
  defp is_nil_or_blank(_), do: false
end
