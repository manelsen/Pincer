defmodule Pincer.Core.Executor do
  @moduledoc """
  The Unified Executor — a polymath agent that reasons through problems.

  The Executor uses Hexagonal Architecture (Ports and Adapters) to remain decoupled
  from specific tool implementations and LLM providers. Dependencies are injected
  at runtime.
  """

  require Logger

  @max_recursion_depth 15
  @approval_timeout_ms 60_000

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
    Logger.info("[EXECUTOR] Starting cycle for #{session_id}")

    deps = resolve_dependencies(opts)

    model_override = Keyword.get(opts, :model_override)
    long_term_memory = Keyword.get(opts, :long_term_memory, "")

    Process.put(:session_pid, session_pid)
    Process.put(:session_id, session_id)
    Process.put(:long_term_memory, long_term_memory)
    Process.put(:executor_deps, deps)

    try do
      case run_loop(history, session_id, session_pid, 0, model_override, deps) do
        {:ok, final_history, response} ->
          send(session_pid, {:executor_finished, final_history, response})

        {:error, reason} ->
          send(session_pid, {:executor_failed, reason})
      end
    rescue
      e ->
        send(session_pid, {:executor_failed, e})
    end
  end

  defp resolve_dependencies(opts) do
    config = Application.get_env(:pincer, :core, [])

    %{
      tool_registry:
        Keyword.get(
          opts,
          :tool_registry,
          config[:tool_registry] || Pincer.Adapters.NativeToolRegistry
        ),
      llm_client: Keyword.get(opts, :llm_client, config[:llm_client] || Pincer.LLM.Client),
      # file_fetcher: fn url -> {:ok, base64} | {:error, reason} end
      # Overridable in tests to avoid real HTTP calls during attachment inlining.
      file_fetcher: Keyword.get(opts, :file_fetcher, &Pincer.Core.Executor.default_file_fetch/1)
    }
  end

  @doc false
  def default_file_fetch(url) do
    case Req.get(url, receive_timeout: 60_000, max_body_length: @max_inline_bytes) do
      {:ok, %{status: 200, body: body}} when is_binary(body) -> {:ok, Base.encode64(body)}
      {:ok, %{status: status}} -> {:error, "HTTP #{status}"}
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

    long_term_memory = Process.get(:long_term_memory, "")
    current_time = DateTime.utc_now() |> DateTime.to_string()

    augmented_history = augment_history(history, long_term_memory, current_time)

    # Resolve lazy attachment_ref parts based on what the active provider supports.
    # We resolve a fresh copy here (not modifying the history kept in state) so that
    # base64-encoded file data never gets persisted back to the session history.
    active_provider = get_active_provider(model_override)
    ready_history = resolve_lazy_attachments(augmented_history, active_provider)

    tools_spec = deps.tool_registry.list_tools()

    Logger.info(
      "[EXECUTOR] Sending prompt to LLM (STREAMING). History size: #{length(ready_history)}"
    )

    case deps.llm_client.stream_completion(ready_history, [tools: tools_spec] ++ client_opts) do
      {:ok, stream} ->
        try do
          handle_stream(stream, history, session_id, session_pid, depth, model_override, deps)
        rescue
          error in Protocol.UndefinedError ->
            Logger.warning(
              "[EXECUTOR] Invalid streaming payload. Falling back to chat completion."
            )

            fallback_chat_completion(
              error,
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
        new_content =
          if memory != "" do
            "#{content}\n\n### TEMPORAL CONTEXT\nCURRENT TIME: #{time}\n\n### NARRATIVE MEMORY\n#{memory}"
          else
            "#{content}\n\n### TEMPORAL CONTEXT\nCURRENT TIME: #{time}"
          end

        [%{sys | "content" => new_content} | rest]

      _ ->
        history
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
      deps
    )
  end

  defp process_chunk(chunk, acc_text, acc_tools, session_pid) do
    case chunk do
      %{"choices" => [%{"delta" => delta}]} ->
        new_text =
          if token = delta["content"] do
            send(session_pid, {:agent_stream_token, token})
            acc_text <> token
          else
            acc_text
          end

        new_tools =
          if tool_deltas = delta["tool_calls"] do
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
      {:ok, message} when is_map(message) ->
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
          deps
        )

      {:ok, other} ->
        {:error, {:invalid_chat_response, other}}

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
         deps
       ) do
    case assistant_msg do
      %{"tool_calls" => tool_calls} when is_list(tool_calls) and tool_calls != [] ->
        tool_names = Enum.map(tool_calls, fn tc -> tc["function"]["name"] end) |> Enum.join(", ")
        Logger.info("[EXECUTOR] LLM decided to use tools: #{tool_names}")
        send(session_pid, {:sme_tool_use, tool_names})

        tool_results =
          Enum.map(tool_calls, fn call ->
            execute_tool_via_registry(call, session_pid, session_id, deps.tool_registry)
          end)

        new_history = history ++ [assistant_msg] ++ tool_results
        run_loop(new_history, session_id, session_pid, depth + 1, model_override, deps)

      %{"content" => content} ->
        Logger.info(
          "[EXECUTOR] LLM stream finished. Text length: #{String.length(content || "")}"
        )

        {:ok, history ++ [assistant_msg], content}

      _ ->
        {:error, {:invalid_assistant_message, assistant_msg}}
    end
  end

  defp merge_tool_deltas(acc, deltas) do
    Enum.reduce(deltas, acc, fn delta, inner_acc ->
      index = delta["index"]

      existing =
        Map.get(inner_acc, index, %{
          "index" => index,
          "id" => nil,
          "function" => %{"name" => "", "arguments" => ""}
        })

      updated =
        existing
        |> Map.put("id", delta["id"] || existing["id"])
        |> update_in(["function", "name"], &((delta["function"]["name"] || "") <> &1))

      name_delta = get_in(delta, ["function", "name"]) || ""

      updated =
        put_in(updated, ["function", "name"], (existing["function"]["name"] || "") <> name_delta)

      args_delta = get_in(delta, ["function", "arguments"]) || ""

      updated =
        put_in(
          updated,
          ["function", "arguments"],
          (existing["function"]["arguments"] || "") <> args_delta
        )

      Map.put(inner_acc, index, updated)
    end)
  end

  defp execute_tool_via_registry(
         %{"id" => call_id, "function" => %{"name" => name, "arguments" => args_json}},
         session_pid,
         session_id,
         registry
       ) do
    Logger.info("[TOOL] Executing #{name}")

    args =
      case Jason.decode(args_json) do
        {:ok, d} -> d
        _ -> args_json
      end

    context = %{"session_id" => session_id}

    result =
      case registry.execute_tool(name, args, context) do
        {:ok, c} ->
          c

        {:error, {:approval_required, cmd}} ->
          handle_approval(call_id, cmd, session_pid, session_id, registry)

        {:error, r} ->
          "Error: #{inspect(r)}"
      end

    %{"role" => "tool", "tool_call_id" => call_id, "name" => name, "content" => to_string(result)}
  end

  defp handle_approval(call_id, command, session_pid, session_id, registry) do
    Logger.warning("[EXECUTOR] Waiting for approval for: #{command}")

    send(
      session_pid,
      {:sme_status, :executor,
       "⚠️ **APPROVAL REQUIRED** (id: #{call_id}): The command `#{command}` is potentially dangerous. Approve or Reject."}
    )

    Pincer.PubSub.broadcast(
      "session:#{session_id}",
      {:agent_thinking, "Waiting for confirmation for: `#{command}`..."}
    )

    Pincer.PubSub.broadcast("session:#{session_id}", {:approval_requested, call_id, command})

    receive do
      {:tool_approval, ^call_id, :granted} ->
        Logger.info("[EXECUTOR] Approval granted for #{command}")

        case registry.execute_tool("run_command", %{"command" => command}, %{
               "session_id" => session_id
             }) do
          {:ok, res} -> res
          {:error, r} -> "Post-approval error: #{inspect(r)}"
        end

      {:tool_approval, ^call_id, :denied} ->
        Logger.warning("[EXECUTOR] Approval denied for #{command}")
        "ERROR: Command execution denied by user."
    after
      @approval_timeout_ms ->
        "ERROR: Timeout waiting for user approval."
    end
  end

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
          "[Arquivo: #{filename} — #{size} bytes — maior que o limite de inlining (#{@max_inline_bytes} bytes). " <>
            "Use uma ferramenta de leitura de arquivos ou reduza o tamanho do documento.]"
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

          %{"type" => "text", "text" => "[Falha ao baixar '#{filename}': #{inspect(reason)}]"}
      end
    end
  end

  defp resolve_part(%{"type" => "attachment_ref"} = ref, _supports = false) do
    %{"filename" => filename, "size" => size} = ref

    %{
      "type" => "text",
      "text" =>
        "[Arquivo '#{filename}' (#{size} bytes) não processado — o provider ativo não suporta leitura de arquivos. " <>
          "Troque para um modelo com suporte multimodal (ex: Gemini) para ler PDFs e imagens.]"
    }
  end

  defp resolve_part(part, _supports), do: part

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
end
