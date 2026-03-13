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
  alias Pincer.Utils.Text

  @max_recursion_depth 25
  @approval_timeout_ms 60_000
  @tool_result_max_chars Application.compile_env(:pincer, :tool_result_max_chars, 32_000)

  # Maximum size for inline data (6MB default for Gemini/Google)
  @max_inline_bytes 6_291_456

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
      file_fetcher: opts[:file_fetcher] || (&default_file_fetch/1)
    }

    # Store workspace path in process dictionary for easy access in nested calls
    workspace_path = opts[:workspace_path] || AgentPaths.workspace_root(session_id)
    Process.put(:workspace_path, workspace_path)
    Process.put(:executor_deps, deps)
    Process.put(:executor_run_opts, opts)

    # 2. Setup initial state
    Logger.info("[EXECUTOR] Starting cycle for #{session_id}")

    try do
      # 3. Enter recursion loop
      # Initial call uses depth 0
      run_loop(history, session_id, session_pid, 0, opts[:model_override], deps)
    after
      Process.delete(:workspace_path)
      Process.delete(:executor_deps)
      Process.delete(:executor_run_opts)
      Process.delete(:consecutive_errors)
    end
    |> case do
      {:ok, final_history, final_content, usage} ->
        send(session_pid, {:executor_finished, final_history, final_content, usage})
        :ok

      {:error, reason} ->
        send(session_pid, {:executor_failed, reason})
        :error
    end
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
    if depth > @max_recursion_depth, do: raise("Excessive recursion in Executor")

    updated_model_override = check_messages(model_override)

    if loop_detected?(logical_history) do
      send(session_pid, {:executor_failed, "Tool loop detected. Aborting."})
      {:error, :tool_loop}
    else
      # Prompt history preparation: Only prune and augment at the beginning of the cycle (Depth 0)
      prompt_history =
        if depth == 0 do
          prepare_prompt_history(logical_history, model_override)
        else
          # At depth > 0, we should have been using run_loop_recursive which passes prompt_history
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
    if depth > @max_recursion_depth, do: raise("Excessive recursion in Executor")

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
    long_term_memory = Process.get(:long_term_memory, "")
    current_time = DateTime.utc_now() |> DateTime.to_string()

    active_provider = get_active_provider(model_override)

    sweet_spot_limit =
      case Pincer.Ports.LLM.provider_config(active_provider) do
        %{context_window: cw} when is_integer(cw) -> max(1000, trunc(cw * 0.45))
        _ -> 8_000
      end

    safe_limit_scale = Keyword.get(opts, :safe_limit_scale, 1.0)
    adjusted_limit = max(1000, trunc(sweet_spot_limit * safe_limit_scale))

    context_strategy = Keyword.get(Process.get(:executor_run_opts, []), :context_strategy)

    # 1. Prune only once
    pruned_history = prune_history(history, adjusted_limit, context_strategy: context_strategy)

    # 2. Augment with dynamic context (Memory, Time, Recall)
    augmented_history = augment_history(pruned_history, long_term_memory, current_time)

    # 3. Resolve lazy attachments
    resolve_lazy_attachments(augmented_history, active_provider)
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
      if model_override,
        do: [provider: model_override.provider, model: model_override.model],
        else: []

    client_opts =
      if thinking = Map.get(model_override || %{}, :thinking_level) do
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

    case deps.llm_client.stream_completion(prompt_history, [tools: tools_spec] ++ client_opts) do
      {:ok, stream} ->
        try do
          handle_stream(
            stream,
            logical_history,
            prompt_history,
            session_id,
            session_pid,
            depth,
            model_override,
            deps
          )
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

      {:error, {:missing_credentials, env_key}} ->
        msg =
          "❌ **Credentials Missing**: The environment variable `#{env_key}` is not set or is empty. Please configure it in your `.env` file and restart the server."

        Pincer.Infra.PubSub.broadcast("session:#{session_id}", {:agent_response, msg})
        {:error, :missing_credentials}

      {:error, reason} ->
        Logger.error("[EXECUTOR] LLM streaming failed: #{inspect(reason)}")

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
        send(session_pid, {:executor_failed, reason})
        {:error, reason}
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

  defp post_tool_grounding_message do
    %{
      "role" => "system",
      "content" =>
        "Ground yourself strictly in the tool outputs above. Do not invent files, results, success, or side effects. If a tool failed, found nothing, or returned limited data, say that plainly."
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
         deps
       ) do
    # State: {full_content, full_reasoning, tool_calls_map, stream_buffer, is_filtering?}
    {full_content, full_reasoning, full_tool_calls, _, _} =
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

    tool_calls_list = format_tool_calls(full_tool_calls)
    content = merge_reasoning_and_content(full_content, full_reasoning)

    assistant_msg = %{
      "role" => "assistant",
      "content" => if(content == "", do: nil, else: content),
      "tool_calls" => tool_calls_list
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
      nil
    )
  end

  defp process_chunk(chunk, acc_text, acc_reasoning, acc_tools, buffer, filtering?, session_pid) do
    case chunk do
      %{"choices" => [%{"delta" => delta}]} ->
        tool_deltas = delta["tool_calls"]
        content = delta["content"] || ""
        reasoning = delta["reasoning"] || delta["reasoning_content"] || ""

        {new_text, new_buffer, new_filtering} =
          if is_binary(content) and content != "" do
            handle_content_token(content, acc_text, buffer, filtering?, session_pid)
          else
            {acc_text, buffer, filtering?}
          end

        new_reasoning =
          if is_binary(reasoning) and reasoning != "" do
            acc_reasoning <> reasoning
          else
            acc_reasoning
          end

        new_tools =
          if tool_deltas do
            merge_tool_deltas(acc_tools, tool_deltas)
          else
            acc_tools
          end

        {new_text, new_reasoning, new_tools, new_buffer, new_filtering}

      _ ->
        {acc_text, acc_reasoning, acc_tools, buffer, filtering?}
    end
  end

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

    cond do
      # 1. Start filtering if we see the beginning of any suspicious tag
      should_start_filtering ->
        # Find which tag triggered it to extract text before it
        trigger_tag = Enum.find(tags, &String.contains?(new_buffer, &1))
        [text_before | _] = String.split(new_buffer, trigger_tag, parts: 2)
        if text_before != "", do: send(session_pid, {:agent_stream_token, text_before})
        {acc_text <> text_before, new_buffer, true}

      # 2. Stop filtering if we see the end of a tag or a closing tag
      filtering? and (String.contains?(new_buffer, ">") or String.contains?(new_buffer, "</")) ->
        # Stop filtering when tag seems complete.
        # CRITICAL: Clear the buffer so the tag doesn't trigger case 1 again on the next token!
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
        send(session_pid, {:sme_tool_use, tool_names})

        tool_results =
          Enum.map(normalized_tool_calls, fn call ->
            execute_tool_via_registry(call, session_pid, session_id, deps.tool_registry)
          end)

        # Update both histories for the next turn
        new_logical_history = logical_history ++ [assistant_msg] ++ tool_results

        new_prompt_history =
          prompt_history ++ [assistant_msg] ++ tool_results ++ [post_tool_grounding_message()]

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

        # Synthesize a fallback if LLM is too laconic after tool usage
        final_content =
          if (is_nil(content) or String.trim(content) == "") and depth > 0 do
            # Try to infer what was done from the last tool result in history
            tool_messages = Enum.filter(Enum.reverse(logical_history), &(&1["role"] == "tool"))

            if tool_messages != [] do
              # Build a summary of what was done
              tool_summary =
                tool_messages
                |> Enum.take(5)
                |> Enum.map(fn msg ->
                  tool_name = msg["name"] || "tool"

                  result_preview =
                    case msg["content"] do
                      nil ->
                        ""

                      content when is_binary(content) ->
                        content
                        |> String.split("\n")
                        |> Enum.take(3)
                        |> Enum.join(" ")
                        |> String.slice(0, 100)

                      _ ->
                        ""
                    end

                  "- #{tool_name}: #{result_preview}"
                end)
                |> Enum.join("\n")

              used_tools =
                tool_messages
                |> Enum.map(&(&1["name"] || "tool"))
                |> Enum.uniq()
                |> Enum.join(", ")

              """
              ✅ Concluído. Ferramentas utilizadas: #{used_tools}

              Resumo das ações:
              #{tool_summary}

              (O assistente não forneceu uma resposta detalhada. Use /verbose on para mais informações.)
              """
              |> String.trim()
            else
              "✅ Concluído."
            end
          else
            content
          end

        assistant_msg = Map.put(assistant_msg, "content", final_content)

        # IMPORTANT: Return clean logical history to session
        {:ok, logical_history ++ [assistant_msg], final_content, usage}

      _ ->
        {:error, {:invalid_assistant_message, assistant_msg}}
    end
  end

  defp augment_history(history, memory, time) do
    case history do
      [%{"role" => "system", "content" => content} = sys | rest] ->
        workspace_path = Process.get(:workspace_path, File.cwd!())

        runtime_memory =
          if memory != "" do
            memory
          else
            AgentPaths.read_file(AgentPaths.memory_path(workspace_path))
          end

        safe_memory = MemoryRecall.sanitize_for_prompt(runtime_memory)
        {learnings, learnings_count} = fetch_active_learnings()

        recall =
          MemoryRecall.build(history,
            workspace_path: workspace_path,
            learnings_count: learnings_count
          ).prompt_block

        new_content =
          if safe_memory != "" do
            "#{content}\n\n### TEMPORAL CONTEXT\nCURRENT TIME: #{time}\n\n### NARRATIVE MEMORY\n#{safe_memory}#{learnings}#{recall}"
          else
            "#{content}\n\n### TEMPORAL CONTEXT\nCURRENT TIME: #{time}#{learnings}#{recall}"
          end

        [%{sys | "content" => new_content} | rest]

      _ ->
        history
    end
  end

  defp fetch_active_learnings do
    case Pincer.Ports.Storage.list_recent_learnings(3) do
      [] ->
        {"", 0}

      learnings ->
        formatted =
          Enum.map_join(learnings, "\n", fn l ->
            case l.type do
              :error ->
                safe_error = MemoryRecall.sanitize_for_prompt(l.error)
                "- [AVOID ERROR] Tool `#{l.tool}` failed recently: #{safe_error}"

              :learning ->
                safe_summary = MemoryRecall.sanitize_for_prompt(l.summary)
                "- [LESSON] #{safe_summary}"
            end
          end)

        {"\n\n### RECENT LEARNINGS & ERRORS (Self-Improvement)\nAvoid repeating these recent mistakes:\n#{formatted}",
         length(learnings)}
    end
  end

  # The "Sweet Spot" architecture for complex reasoning:
  # We preserve the Fixed Injection (System Prompt) and a strict window of recent turns.
  # "Lost in the Middle" context is dropped. The agent must use GraphMemory to recall old facts.
  @max_recent_messages 15

  defp prune_history([], _safe_limit, _opts), do: []

  defp prune_history([%{"role" => "system"} = system_msg | rest], safe_limit, opts) do
    if Keyword.get(opts, :context_strategy) == :conversation_summary and
         length(rest) > 30 do
      summarize_and_prune(system_msg, rest, safe_limit)
    else
      # 1. Enforce strict episodic window (drop the "Lost in the Middle")
      recent_messages =
        if length(rest) > @max_recent_messages do
          Enum.drop(rest, length(rest) - @max_recent_messages)
        else
          rest
        end

      # 2. Reverse to process newest messages first for the token cap
      reversed_recent = Enum.reverse(recent_messages)

      # 3. Accumulate tokens backwards
      {kept_messages, _tokens} =
        Enum.reduce_while(reversed_recent, {[], 0}, fn msg, {acc_msgs, acc_tokens} ->
          msg_tokens = Pincer.Utils.Tokenizer.estimate(msg)
          new_total = acc_tokens + msg_tokens

          # We always keep at least one message (the newest one), even if it's huge
          if new_total <= safe_limit or acc_msgs == [] do
            {:cont, {[msg | acc_msgs], new_total}}
          else
            {:halt, {acc_msgs, acc_tokens}}
          end
        end)

      # 4. Reconstruct chronologically (system prompt + kept episodic memory)
      [system_msg | kept_messages]
    end
  end

  defp prune_history(history, safe_limit, _opts) do
    # Fallback for histories without a system prompt at the head (usually testing only)
    recent_messages =
      if length(history) > @max_recent_messages do
        Enum.drop(history, length(history) - @max_recent_messages)
      else
        history
      end

    reversed_recent = Enum.reverse(recent_messages)

    {kept_messages, _tokens} =
      Enum.reduce_while(reversed_recent, {[], 0}, fn msg, {acc_msgs, acc_tokens} ->
        msg_tokens = Pincer.Utils.Tokenizer.estimate(msg)
        new_total = acc_tokens + msg_tokens

        if new_total <= safe_limit or acc_msgs == [] do
          {:cont, {[msg | acc_msgs], new_total}}
        else
          {:halt, {acc_msgs, acc_tokens}}
        end
      end)

    kept_messages
  end

  defp summarize_and_prune(system_msg, rest, safe_limit) do
    recent_count = min(@max_recent_messages, length(rest))
    recent_messages = Enum.drop(rest, length(rest) - recent_count)
    to_summarize = Enum.drop(rest, recent_count)

    messages_text =
      Enum.map_join(to_summarize, "\n", fn msg ->
        role = msg["role"] || "unknown"
        content = msg["content"] || ""
        "#{role}: #{content}"
      end)

    summary =
      case summarize_via_llm(messages_text) do
        {:ok, text} ->
          text

        _ ->
          Logger.warning("[EXECUTOR] conversation_summary LLM call failed; skipping summary.")
          nil
      end

    if summary do
      summary_msg = %{
        "role" => "system",
        "content" => "## Previous Conversation Summary\n\n#{summary}"
      }

      reversed_recent = Enum.reverse(recent_messages)

      {kept_messages, _tokens} =
        Enum.reduce_while(reversed_recent, {[], 0}, fn msg, {acc_msgs, acc_tokens} ->
          msg_tokens = Pincer.Utils.Tokenizer.estimate(msg)
          new_total = acc_tokens + msg_tokens

          if new_total <= safe_limit or acc_msgs == [] do
            {:cont, {[msg | acc_msgs], new_total}}
          else
            {:halt, {acc_msgs, acc_tokens}}
          end
        end)

      [system_msg, summary_msg | kept_messages]
    else
      prune_history([system_msg | rest], safe_limit, [])
    end
  end

  defp summarize_via_llm(messages_text) do
    prompt = [
      %{
        "role" => "user",
        "content" =>
          "Summarize this conversation in 3-5 sentences, preserving key decisions and context:\n\n#{messages_text}"
      }
    ]

    client =
      case Process.get(:executor_deps) do
        %{llm_client: c} -> c
        _ -> Pincer.Ports.LLM
      end

    case client.chat_completion(prompt, []) do
      {:ok, %{"content" => content}, _usage} when is_binary(content) -> {:ok, content}
      _ -> {:error, :summary_failed}
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

    args = parse_tool_arguments(raw_arguments)

    workspace_path = Process.get(:workspace_path)

    context = %{
      "session_id" => session_id,
      "workspace_path" => workspace_path,
      session_id: session_id,
      workspace_path: workspace_path
    }

    result =
      case registry.execute_tool(name, args, context) do
        {:ok, c} ->
          Process.put(:consecutive_errors, 0)
          c

        {:error, {:approval_required, cmd}} ->
          Process.put(:consecutive_errors, 0)
          handle_approval(call_id, cmd, session_pid, session_id, registry)

        {:error, r} ->
          errors = Process.get(:consecutive_errors, 0) + 1
          Process.put(:consecutive_errors, errors)

          # Auto-capture error if it repeats
          if errors >= 3 do
            Logger.warning(
              "[SELF-IMPROVEMENT] Consecutive tool error detected. Capturing to Graph."
            )

            Pincer.Ports.Storage.save_tool_error(name, args, inspect(r))
          end

          "Error: #{inspect(r)}"
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

    %{"role" => "tool", "tool_call_id" => call_id, "name" => name, "content" => content}
  end

  defp execute_tool_via_registry(_invalid_call, _session_pid, _session_id, _registry) do
    %{
      "role" => "tool",
      "tool_call_id" => "tool_call_invalid",
      "name" => "unknown_tool",
      "content" => "Error: invalid tool call payload."
    }
  end

  defp handle_approval(call_id, command, session_pid, session_id, registry) do
    Logger.warning("[EXECUTOR] Waiting for approval for: #{command}")

    send(
      session_pid,
      {:sme_status, :executor,
       "⚠️ **APPROVAL REQUIRED** (id: #{call_id}): The command `#{command}` is potentially dangerous. Approve or Reject."}
    )

    Pincer.Infra.PubSub.broadcast(
      "session:#{session_id}",
      {:approval_required, call_id, command}
    )

    # We wait synchronously here but the session GenServer remains responsive
    # to the user input because this is running in a spawned task.
    receive do
      {:tool_approval_result, ^call_id, :approved} ->
        Logger.info("[EXECUTOR] Command approved: #{command}")

        case registry.execute_tool(
               "safe_shell",
               %{"command" => command, "skip_approval" => true},
               %{
                 "session_id" => session_id
               }
             ) do
          {:ok, result} -> result
          {:error, reason} -> "Error: #{inspect(reason)}"
        end

      {:tool_approval_result, ^call_id, :rejected} ->
        Logger.info("[EXECUTOR] Command rejected: #{command}")
        "Error: Command rejected by user."
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
                  send(session_pid, {:agent_status, msg})

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

  defp format_tool_calls(full_tool_calls) do
    if map_size(full_tool_calls) > 0 do
      full_tool_calls
      |> Map.values()
      |> Enum.sort_by(& &1["index"])
      |> Enum.map(fn map -> Map.delete(map, "index") end)
    else
      nil
    end
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
      {:ok, args} -> args
      _ -> %{}
    end
  end

  defp parse_tool_arguments(args) when is_map(args), do: args
  defp parse_tool_arguments(_), do: %{}

  defp ensure_tool_call_type(call) do
    call |> Map.put_new("type", "function")
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

  # Check 2: any single tool name appearing 10+ times in the last 15 assistant turns.
  defp high_frequency_loop?(history) do
    recent_names =
      history
      |> Enum.take(-15)
      |> Enum.flat_map(fn
        %{"tool_calls" => calls} when not is_nil(calls) ->
          Enum.map(calls, fn tc -> get_in(tc, ["function", "name"]) end)

        _ ->
          []
      end)
      |> Enum.reject(&is_nil/1)

    Enum.any?(
      Enum.frequencies(recent_names),
      fn {_tool, count} -> count >= 10 end
    )
  end

  defp tool_call_name(tool_call) when is_map(tool_call) do
    get_in(tool_call, ["function", "name"]) || get_in(tool_call, [:function, :name])
  end

  defp tool_call_name(_), do: nil

  defp get_active_provider(model_override) do
    if model_override do
      model_override.provider
    else
      Pincer.Infra.Config.get(:llm)["provider"] || "openrouter"
    end
  end

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
    Enum.map(history, fn msg ->
      if is_list(msg["content"]) do
        resolved_content =
          Enum.map(msg["content"], fn
            %{"type" => "attachment", "attachment" => att} = part ->
              case resolve_attachment_part(att, provider) do
                {:ok, resolved} -> resolved
                {:error, _} -> part
              end

            part ->
              part
          end)

        Map.put(msg, "content", resolved_content)
      else
        msg
      end
    end)
  end

  defp resolve_attachment_part(att, provider) do
    resolve_attachment_fallback(att, provider)
  end

  defp resolve_attachment_fallback(att, _provider) do
    # Generic fallback: download and encode as base64 inlineData if it is an image or PDF
    case att.mime_type do
      mime when mime in ["image/png", "image/jpeg", "image/webp", "application/pdf"] ->
        case download_as_base64(att.url) do
          {:ok, b64} ->
            {:ok,
             %{
               "type" => "image_url",
               "image_url" => %{"url" => "data:#{mime};base64,#{b64}"}
             }}

          error ->
            error
        end

      _ ->
        {:error, :unsupported_fallback}
    end
  end

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
