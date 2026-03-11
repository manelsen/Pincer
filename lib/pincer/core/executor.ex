defmodule Pincer.Core.Executor do
  @moduledoc """
  The Unified Executor — a polymath agent that reasons through problems.

  The Executor uses Hexagonal Architecture (Ports and Adapters) to remain decoupled
  from specific tool implementations and LLM providers. Dependencies are injected
  at runtime.
  """

  require Logger
  alias Pincer.Core.AgentPaths
  alias Pincer.Core.MemoryRecall

  @max_recursion_depth 15
  @approval_timeout_ms 60_000
  @markdown_notice_max_chars 12_000
  @markdown_ignored_roots MapSet.new([".git", "_build", "deps", "node_modules", "target"])
  @tool_result_max_chars Application.compile_env(:pincer, :tool_result_max_chars, 32_000)

  # Maximum file size for inline base64 encoding (≈10 MB decoded → ≈13.3 MB base64).
  # Larger files are described as text instead of sent inline.
  @max_inline_bytes 10_485_760

  @doc """
  Starts a new executor task.
  """
  def start(session_pid, session_id, history, opts \\ []) do
    Task.start(fn ->
      run(session_pid, session_id, history, opts)
    end)
  end

  @doc false
  def run(session_pid, session_id, history, opts) do
    Logger.metadata(session_id: session_id)
    Logger.info("[EXECUTOR] Starting cycle for #{session_id}")

    deps = resolve_dependencies(opts)

    model_override = Keyword.get(opts, :model_override)
    long_term_memory = Keyword.get(opts, :long_term_memory, "")
    workspace_path = Keyword.get(opts, :workspace_path, File.cwd!())

    Process.put(:session_pid, session_pid)
    Process.put(:session_id, session_id)
    Process.put(:workspace_path, workspace_path)
    Process.put(:long_term_memory, long_term_memory)
    Process.put(:executor_deps, deps)
    Process.put(:executor_run_opts, opts)
    init_markdown_tracker(workspace_path)

    try do
      case run_loop(history, session_id, session_pid, 0, model_override, deps) do
        {:ok, final_history, response, usage} ->
          send(session_pid, {:executor_finished, final_history, response, usage})

        {:error, reason} ->
          send(session_pid, {:executor_failed, reason})
      end
    rescue
      e ->
        send(session_pid, {:executor_failed, e})
    end
  end

  defp resolve_dependencies(opts) do
    %{
      tool_registry: Keyword.get(opts, :tool_registry, Pincer.Ports.ToolRegistry),
      llm_client: Keyword.get(opts, :llm_client, Pincer.Ports.LLM),
      # file_fetcher: fn url -> {:ok, base64} | {:error, reason} end
      # Overridable in tests to avoid real HTTP calls during attachment inlining.
      file_fetcher: Keyword.get(opts, :file_fetcher, &Pincer.Core.Executor.default_file_fetch/1)
    }
  end

  @doc false
  @spec resolve_attachment_url(String.t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, :invalid_attachment_url | :telegram_token_missing}
  def resolve_attachment_url(url, token \\ nil)

  def resolve_attachment_url("telegram://file/" <> file_path, token) do
    normalized_path = String.trim(file_path)

    cond do
      normalized_path == "" ->
        {:error, :invalid_attachment_url}

      true ->
        resolved_token =
          token || Application.get_env(:telegex, :token) || System.get_env("TELEGRAM_BOT_TOKEN")

        if is_binary(resolved_token) and String.trim(resolved_token) != "" do
          {:ok, "https://api.telegram.org/file/bot#{resolved_token}/#{normalized_path}"}
        else
          {:error, :telegram_token_missing}
        end
    end
  end

  def resolve_attachment_url(url, _token) when is_binary(url), do: {:ok, url}
  def resolve_attachment_url(_url, _token), do: {:error, :invalid_attachment_url}

  @doc false
  def default_file_fetch(url) do
    with {:ok, resolved_url} <- resolve_attachment_url(url),
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

  defp run_loop(history, session_id, session_pid, depth, model_override, deps) do
    if depth > @max_recursion_depth, do: raise("Excessive recursion in Executor")

    updated_model_override = check_messages(model_override)

    if loop_detected?(history) do
      send(session_pid, {:executor_failed, "Tool loop detected. Aborting."})
      {:error, :tool_loop}
    else
      do_run_loop(history, session_id, session_pid, depth, updated_model_override, deps)
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

  defp do_run_loop(history, session_id, session_pid, depth, model_override, deps) do
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

    long_term_memory = Process.get(:long_term_memory, "")
    current_time = DateTime.utc_now() |> DateTime.to_string()

    # Determine Sweet Spot token limit based on active provider's context window.
    # Consensus for complex reasoning ("Lost in the Middle"): cap at ~25% of absolute max.
    active_provider = get_active_provider(model_override)

    sweet_spot_limit =
      case Pincer.Ports.LLM.provider_config(active_provider) do
        %{context_window: cw} when is_integer(cw) -> max(1000, trunc(cw * 0.25))
        # Default safe reasoning fallback
        _ -> 8_000
      end

    context_strategy = Keyword.get(Process.get(:executor_run_opts, []), :context_strategy)

    # 1. Prune history using the episodic Sweet Spot architecture
    pruned_history = prune_history(history, sweet_spot_limit, context_strategy: context_strategy)

    augmented_history = augment_history(pruned_history, long_term_memory, current_time)

    # Resolve lazy attachment_ref parts based on what the active provider supports.
    # We resolve a fresh copy here (not modifying the history kept in state) so that
    # base64-encoded file data never gets persisted back to the session history.
    ready_history = resolve_lazy_attachments(augmented_history, active_provider)

    tools_spec = deps.tool_registry.list_tools()

    Logger.info(
      "[EXECUTOR] Sending prompt to LLM (STREAMING). History size: #{length(ready_history)}"
    )

    case deps.llm_client.stream_completion(ready_history, [tools: tools_spec] ++ client_opts) do
      {:ok, stream} ->
        try do
          handle_stream(
            stream,
            pruned_history,
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
              ready_history,
              pruned_history,
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
          ready_history,
          history,
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

  defp handle_stream(stream, history, session_id, session_pid, depth, model_override, deps) do
    {full_content, full_tool_calls} =
      Enum.reduce(stream, {"", %{}}, fn chunk, {acc_text, acc_tools} ->
        process_chunk(chunk, acc_text, acc_tools, session_pid)
      end)

    tool_calls_list = format_tool_calls(full_tool_calls)

    assistant_msg = %{
      "role" => "assistant",
      "content" => if(full_content == "", do: nil, else: full_content),
      "tool_calls" => tool_calls_list
    }

    finalize_assistant_message(
      assistant_msg,
      history,
      session_id,
      session_pid,
      depth,
      model_override,
      deps,
      nil
    )
  end

  defp process_chunk(chunk, acc_text, acc_tools, session_pid) do
    case chunk do
      %{"choices" => [%{"delta" => delta}]} ->
        tool_deltas = delta["tool_calls"]

        new_text =
          case {tool_deltas, delta["content"]} do
            {nil, token} when is_binary(token) and token != "" ->
              send(session_pid, {:agent_stream_token, token})
              acc_text <> token

            _ ->
              acc_text
          end

        new_tools =
          if tool_deltas do
            merge_tool_deltas(acc_tools, tool_deltas)
          else
            acc_tools
          end

        {new_text, new_tools}

      _ ->
        {acc_text, acc_tools}
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

  defp fallback_chat_completion(
         stream_reason,
         ready_history,
         history,
         session_id,
         session_pid,
         depth,
         model_override,
         deps,
         client_opts,
         tools_spec
       ) do
    Logger.warning("[EXECUTOR] Streaming fallback reason: #{inspect(stream_reason)}")

    case deps.llm_client.chat_completion(ready_history, [tools: tools_spec] ++ client_opts) do
      {:ok, message, usage} when is_map(message) ->
        assistant_msg = %{
          "role" => "assistant",
          "content" => message["content"],
          "tool_calls" => message["tool_calls"]
        }

        finalize_assistant_message(
          assistant_msg,
          history,
          session_id,
          session_pid,
          depth,
          model_override,
          deps,
          usage
        )

      {:ok, other} ->
        {:error, {:invalid_chat_response, other}}

      {:error, {:missing_credentials, env_key}} ->
        msg =
          "❌ **Credentials Missing**: The environment variable `#{env_key}` is not set or is empty."

        Pincer.Infra.PubSub.broadcast("session:#{session_id}", {:agent_response, msg})
        {:error, :missing_credentials}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp finalize_assistant_message(
         assistant_msg,
         history,
         session_id,
         session_pid,
         depth,
         model_override,
         deps,
         usage
       ) do
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

        new_history = history ++ [assistant_msg] ++ tool_results
        run_loop(new_history, session_id, session_pid, depth + 1, model_override, deps)

      %{"content" => content} ->
        Logger.info(
          "[EXECUTOR] LLM stream finished. Text length: #{String.length(content || "")}"
        )

        {:ok, history ++ [assistant_msg], content, usage}

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
        |> normalize_tool_call_type()

      name_delta =
        function_delta
        |> read_map_field("name", :name)
        |> normalize_delta_fragment()

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
    context = %{"session_id" => session_id, "workspace_path" => workspace_path}

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

    text = to_string(result)

    text =
      if String.length(text) > @tool_result_max_chars do
        truncated = String.slice(text, 0, @tool_result_max_chars)
        truncated <> "\n[...resultado truncado — #{String.length(text)} chars originais]"
      else
        text
      end

    %{"role" => "tool", "tool_call_id" => call_id, "name" => name, "content" => text}
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
      {:agent_thinking, "Waiting for confirmation for: `#{command}`..."}
    )

    Pincer.Infra.PubSub.broadcast(
      "session:#{session_id}",
      {:approval_requested, call_id, command}
    )

    receive do
      {:tool_approval, ^call_id, :granted} ->
        Logger.info("[EXECUTOR] Approval granted for #{command}")
        workspace_restrict = restrict_to_workspace_enabled?()
        workspace_root = Process.get(:workspace_path) || File.cwd!()

        case Pincer.Core.WorkspaceGuard.command_allowed?(command,
               workspace_restrict: workspace_restrict,
               workspace_root: workspace_root
             ) do
          :ok ->
            case registry.execute_tool(
                   "run_command",
                   %{"command" => command, "cwd" => workspace_root},
                   %{"session_id" => session_id}
                 ) do
              {:ok, res} -> res
              {:error, r} -> "Post-approval error: #{inspect(r)}"
            end

          {:error, reason} ->
            Logger.warning(
              "[EXECUTOR] Approved command denied by workspace restriction policy: #{reason}"
            )

            "ERROR: Command denied by workspace restriction policy. #{reason}"
        end

      {:tool_approval, ^call_id, :denied} ->
        Logger.warning("[EXECUTOR] Approval denied for #{command}")
        "ERROR: Command execution denied by user."
    after
      @approval_timeout_ms ->
        "ERROR: Timeout waiting for user approval."
    end
  end

  defp restrict_to_workspace_enabled? do
    tools = Application.get_env(:pincer, :tools, %{})

    case read_tools_setting(tools, ["restrict_to_workspace", "restrictToWorkspace"]) do
      false -> false
      _ -> true
    end
  end

  defp read_tools_setting(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn key ->
      Map.get(map, key) ||
        Enum.find_value(map, fn
          {existing_key, value} when is_atom(existing_key) ->
            if Atom.to_string(existing_key) == key, do: value

          _ ->
            nil
        end)
    end)
  end

  defp read_tools_setting(_map, _keys), do: nil

  # ---------------------------------------------------------------------------
  # Lazy attachment resolution
  # ---------------------------------------------------------------------------

  # Returns the provider key that will be used for the next LLM call.
  defp get_active_provider(nil) do
    registry = Application.get_env(:pincer, :llm_providers, %{})

    Application.get_env(
      :pincer,
      :default_llm_provider,
      case Map.keys(registry) do
        [first | _] -> first
        _ -> "mock"
      end
    )
  end

  defp get_active_provider(%{provider: provider}), do: provider

  # Returns true when the provider config declares native file/multimodal support.
  defp provider_supports_files?(provider_id) do
    registry = Application.get_env(:pincer, :llm_providers, %{})
    config = Map.get(registry, provider_id, %{})
    Map.get(config, :supports_files, false)
  end

  # Walk the history and resolve any attachment_ref parts.
  defp resolve_lazy_attachments(history, provider_id) do
    supports = provider_supports_files?(provider_id)
    Enum.map(history, &resolve_message_attachments(&1, supports))
  end

  defp resolve_message_attachments(%{"content" => parts} = msg, supports) when is_list(parts) do
    resolved = Enum.map(parts, &resolve_part(&1, supports))
    %{msg | "content" => resolved}
  end

  defp resolve_message_attachments(msg, _supports), do: msg

  defp resolve_part(%{"type" => "attachment_ref"} = ref, _supports = true) do
    %{"url" => url, "mime_type" => mime, "filename" => filename, "size" => size} = ref

    if size > @max_inline_bytes do
      Logger.warning(
        "[EXECUTOR] Attachment '#{filename}' (#{size} bytes) exceeds inline limit; describing as text."
      )

      %{
        "type" => "text",
        "text" =>
          "[File: #{filename} — #{size} bytes — exceeds inline limit (#{@max_inline_bytes} bytes). " <>
            "Use a file-reading tool or reduce the document size.]"
      }
    else
      case download_as_base64(url) do
        {:ok, data} ->
          Logger.info("[EXECUTOR] Inlined attachment '#{filename}' (#{size} bytes, #{mime}).")
          %{"type" => "inline_data", "mime_type" => mime, "data" => data}

        {:error, reason} ->
          Logger.error(
            "[EXECUTOR] Failed to download attachment '#{filename}': #{inspect(reason)}"
          )

          %{"type" => "text", "text" => "[Failed to download '#{filename}': #{inspect(reason)}]"}
      end
    end
  end

  defp resolve_part(%{"type" => "attachment_ref", "mime_type" => mime} = ref, _supports = false)
       when is_binary(mime) do
    if String.starts_with?(String.downcase(mime), "text/") do
      resolve_text_attachment_for_text_only_provider(ref)
    else
      resolve_unsupported_attachment_ref(ref)
    end
  end

  defp resolve_part(%{"type" => "attachment_ref"} = ref, _supports = false) do
    resolve_unsupported_attachment_ref(ref)
  end

  defp resolve_part(part, _supports), do: part

  defp resolve_unsupported_attachment_ref(ref) do
    %{"filename" => filename, "size" => size} = ref

    %{
      "type" => "text",
      "text" =>
        "[File '#{filename}' (#{size} bytes) not processed — the active provider does not support file reading. " <>
          "Switch to a multimodal model (e.g. Gemini) to read PDFs and images.]"
    }
  end

  defp resolve_text_attachment_for_text_only_provider(ref) do
    %{"filename" => filename, "size" => size, "url" => url} = ref

    if size > @max_inline_bytes do
      case download_as_base64(url) do
        {:ok, data} ->
          case Base.decode64(data) do
            {:ok, binary} ->
              # Read a 10KB preview
              preview = String.slice(binary_to_utf8(binary), 0, 10_000)

              %{
                "type" => "text",
                "text" =>
                  "--- Content of #{filename} (PREVIEW - #{size} bytes) ---\n#{preview}\n\n[... File too large for full inlining. Use 'read_file' or 'grep' to see specific parts if needed.]"
              }

            :error ->
              %{
                "type" => "text",
                "text" => "[Failed to decode text file '#{filename}' to UTF-8.]"
              }
          end

        {:error, reason} ->
          %{"type" => "text", "text" => "[Failed to download '#{filename}': #{inspect(reason)}]"}
      end
    else
      case download_as_base64(url) do
        {:ok, data} ->
          case Base.decode64(data) do
            {:ok, binary} ->
              safe_text = binary_to_utf8(binary)
              %{"type" => "text", "text" => "--- Content of #{filename} ---\n#{safe_text}"}

            :error ->
              %{
                "type" => "text",
                "text" => "[Failed to decode text file '#{filename}' to UTF-8.]"
              }
          end

        {:error, reason} ->
          %{"type" => "text", "text" => "[Failed to download '#{filename}': #{inspect(reason)}]"}
      end
    end
  end

  defp binary_to_utf8(binary) when is_binary(binary) do
    if String.valid?(binary) do
      binary
    else
      :unicode.characters_to_binary(binary, :latin1, :utf8)
    end
  rescue
    _ -> binary
  end

  defp download_as_base64(url) do
    fetcher =
      case Process.get(:executor_deps) do
        %{file_fetcher: f} -> f
        _ -> &Pincer.Core.Executor.default_file_fetch/1
      end

    fetcher.(url)
  end

  defp loop_detected?(history) do
    identical_sequence_loop?(history) or high_frequency_loop?(history)
  end

  # Check 1 (original): 3+ consecutive assistant messages with identical tool_call sets.
  defp identical_sequence_loop?(history) do
    tool_calls =
      Enum.filter(Enum.take(history, -6), fn
        %{"tool_calls" => calls} -> not is_nil(calls)
        _ -> false
      end)

    if length(tool_calls) >= 3 do
      first = List.first(tool_calls)["tool_calls"]
      Enum.all?(tool_calls, fn msg -> msg["tool_calls"] == first end)
    else
      false
    end
  end

  # Check 2 (new): any single tool name appearing 5+ times in the last 10 assistant turns.
  defp high_frequency_loop?(history) do
    recent_names =
      history
      |> Enum.take(-10)
      |> Enum.flat_map(fn
        %{"tool_calls" => calls} when not is_nil(calls) ->
          Enum.map(calls, fn tc -> get_in(tc, ["function", "name"]) end)

        _ ->
          []
      end)
      |> Enum.reject(&is_nil/1)

    Enum.any?(
      Enum.frequencies(recent_names),
      fn {_tool, count} -> count >= 5 end
    )
  end

  defp tool_call_name(tool_call) when is_map(tool_call) do
    tool_call
    |> read_map_field("function", :function)
    |> read_map_field("name", :name)
    |> normalize_binary()
  end

  defp tool_call_name(_), do: nil

  defp normalize_tool_call(tool_call) do
    call_id =
      tool_call
      |> read_map_field("id", :id)
      |> normalize_binary()
      |> case do
        nil -> "tool_call_" <> Integer.to_string(System.unique_integer([:positive]))
        value -> value
      end

    function = read_map_field(tool_call, "function", :function)

    name =
      function
      |> read_map_field("name", :name)
      |> normalize_binary()
      |> case do
        nil -> "unknown_tool"
        value -> value
      end

    raw_arguments = read_map_field(function, "arguments", :arguments)

    {call_id, name, raw_arguments}
  end

  defp parse_tool_arguments(nil), do: %{}
  defp parse_tool_arguments(args) when is_map(args), do: normalize_map_keys(args)

  defp parse_tool_arguments(args_json) when is_binary(args_json) do
    trimmed = String.trim(args_json)

    if trimmed == "" do
      %{}
    else
      case Jason.decode(trimmed) do
        {:ok, decoded} when is_map(decoded) ->
          normalize_map_keys(decoded)

        {:ok, decoded} ->
          decoded

        _ ->
          args_json
      end
    end
  end

  defp parse_tool_arguments(other), do: other

  defp normalize_map_keys(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      normalized_key =
        cond do
          is_binary(key) -> key
          is_atom(key) -> Atom.to_string(key)
          true -> to_string(key)
        end

      normalized_value =
        cond do
          is_map(value) -> normalize_map_keys(value)
          is_list(value) -> Enum.map(value, &normalize_nested_value/1)
          true -> value
        end

      Map.put(acc, normalized_key, normalized_value)
    end)
  end

  defp normalize_map_keys(other), do: other

  defp normalize_nested_value(value) when is_map(value), do: normalize_map_keys(value)

  defp normalize_nested_value(value) when is_list(value),
    do: Enum.map(value, &normalize_nested_value/1)

  defp normalize_nested_value(value), do: value

  defp normalize_delta_fragment(nil), do: ""
  defp normalize_delta_fragment(fragment) when is_binary(fragment), do: fragment
  defp normalize_delta_fragment(fragment), do: to_string(fragment)

  defp normalize_arguments_fragment(nil), do: ""
  defp normalize_arguments_fragment(fragment) when is_binary(fragment), do: fragment

  defp normalize_arguments_fragment(fragment) do
    case Jason.encode(fragment) do
      {:ok, json} -> json
      _ -> inspect(fragment)
    end
  end

  defp ensure_tool_call_type(tool_call) when is_map(tool_call) do
    type =
      tool_call
      |> read_map_field("type", :type)
      |> normalize_tool_call_type()
      |> case do
        nil -> "function"
        value -> value
      end

    Map.put(tool_call, "type", type)
  end

  defp ensure_tool_call_type(other), do: other

  defp normalize_tool_call_type(nil), do: nil

  defp normalize_tool_call_type(type) when is_binary(type) do
    case String.trim(type) do
      "" -> nil
      value -> value
    end
  end

  defp normalize_tool_call_type(type) when is_atom(type),
    do: type |> Atom.to_string() |> normalize_tool_call_type()

  defp normalize_tool_call_type(_), do: nil

  defp init_markdown_tracker(workspace_path) do
    root = Path.expand(workspace_path)
    Process.put(:executor_markdown_root, root)
    Process.put(:executor_markdown_snapshot, markdown_snapshot(root))
  rescue
    error ->
      Logger.warning(
        "[EXECUTOR] Failed to initialize markdown tracker: #{Exception.message(error)}"
      )

      Process.put(:executor_markdown_root, nil)
      Process.put(:executor_markdown_snapshot, %{})
  end

  defp maybe_send_markdown_artifacts(session_pid) when is_pid(session_pid) do
    root = Process.get(:executor_markdown_root)
    previous = Process.get(:executor_markdown_snapshot, %{})

    if is_binary(root) and is_map(previous) do
      current = markdown_snapshot(root)

      changed_rel_paths =
        current
        |> Enum.filter(fn {rel_path, metadata} ->
          Map.get(previous, rel_path) != metadata
        end)
        |> Enum.map(&elem(&1, 0))
        |> Enum.sort()

      Enum.each(changed_rel_paths, fn rel_path ->
        case read_markdown_notice_content(root, rel_path) do
          {:ok, content} ->
            send(session_pid, {:sme_status, :executor, markdown_notice(rel_path, content)})

          :error ->
            :ok
        end
      end)

      Process.put(:executor_markdown_snapshot, current)
    end
  rescue
    error ->
      Logger.warning("[EXECUTOR] Markdown artifact tracking failed: #{Exception.message(error)}")
  end

  defp maybe_send_markdown_artifacts(_session_pid), do: :ok

  defp markdown_snapshot(root) do
    root
    |> collect_markdown_files()
    |> Enum.reduce(%{}, fn rel_path, acc ->
      full_path = Path.join(root, rel_path)

      case File.stat(full_path, time: :posix) do
        {:ok, %File.Stat{type: :regular, mtime: mtime, size: size}} ->
          Map.put(acc, rel_path, %{mtime: mtime, size: size})

        _ ->
          acc
      end
    end)
  rescue
    _ -> %{}
  end

  defp collect_markdown_files(root) do
    walk_markdown_files(root, "", [])
  end

  defp walk_markdown_files(root, rel_dir, acc) do
    current_dir = if rel_dir == "", do: root, else: Path.join(root, rel_dir)

    case File.ls(current_dir) do
      {:ok, entries} ->
        Enum.reduce(entries, acc, fn entry, inner_acc ->
          rel_path = if rel_dir == "", do: entry, else: Path.join(rel_dir, entry)
          full_path = Path.join(root, rel_path)

          cond do
            ignored_markdown_path?(rel_path) ->
              inner_acc

            true ->
              case File.stat(full_path) do
                {:ok, %File.Stat{type: :directory}} ->
                  walk_markdown_files(root, rel_path, inner_acc)

                {:ok, %File.Stat{type: :regular}} ->
                  if markdown_file?(rel_path) do
                    [rel_path | inner_acc]
                  else
                    inner_acc
                  end

                _ ->
                  inner_acc
              end
          end
        end)

      {:error, _reason} ->
        acc
    end
  end

  defp ignored_markdown_path?(rel_path) when is_binary(rel_path) do
    case Path.split(rel_path) do
      [head | _tail] -> MapSet.member?(@markdown_ignored_roots, head)
      _ -> false
    end
  end

  defp ignored_markdown_path?(_), do: false

  defp markdown_file?(rel_path) when is_binary(rel_path) do
    String.downcase(Path.extname(rel_path)) == ".md"
  end

  defp markdown_file?(_), do: false

  defp read_markdown_notice_content(root, rel_path) do
    full_path = Path.join(root, rel_path)

    case File.read(full_path) do
      {:ok, content} ->
        truncated =
          if String.length(content) > @markdown_notice_max_chars do
            String.slice(content, 0, @markdown_notice_max_chars) <>
              "\n\n[... markdown truncated for preview ...]"
          else
            content
          end

        {:ok, truncated}

      {:error, _reason} ->
        :error
    end
  end

  defp markdown_notice(rel_path, content) do
    """
    📄 Markdown artifact updated: `#{rel_path}`

    #{content}
    """
    |> String.trim()
  end

  defp read_map_field(map, string_key, atom_key) when is_map(map) do
    Map.get(map, string_key) || Map.get(map, atom_key)
  end

  defp read_map_field(_map, _string_key, _atom_key), do: nil

  defp normalize_binary(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_binary(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_binary()

  defp normalize_binary(value) when is_integer(value),
    do: value |> Integer.to_string() |> normalize_binary()

  defp normalize_binary(_), do: nil

  defp is_nil_or_blank(nil), do: true
  defp is_nil_or_blank(value) when is_binary(value), do: String.trim(value) == ""
  defp is_nil_or_blank(_), do: false
end
