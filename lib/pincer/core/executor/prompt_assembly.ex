defmodule Pincer.Core.Executor.PromptAssembly do
  @moduledoc """
  Builds prompt history for the executor by composing pruning and system-context augmentation.

  This module centralizes the non-transport prompt preparation logic so the
  executor loop only coordinates execution and recovery paths.
  """

  require Logger
  alias Pincer.Core.AgentPaths
  alias Pincer.Core.Memory.CuratedMemory
  alias Pincer.Core.Memory.MemoryRecall
  alias Pincer.Core.Executor.Pruner

  @max_recent_messages 15

  @doc """
  Returns `true` when the workspace bootstrap ritual is still active.

  Once both `IDENTITY.md` and `SOUL.md` exist inside `.pincer/`, bootstrap is
  considered complete even if `BOOTSTRAP.md` remains on disk.
  """
  @spec bootstrap_active?(String.t(), keyword()) :: boolean()
  def bootstrap_active?(workspace_path, opts \\ []) when is_binary(workspace_path) do
    has_identity? = File.exists?(AgentPaths.identity_path(workspace_path))
    has_soul? = File.exists?(AgentPaths.soul_path(workspace_path))

    if has_identity? and has_soul? do
      false
    else
      AgentPaths.bootstrap_active?(workspace_path, opts)
    end
  end

  @doc """
  Builds the initial system prompt from workspace persona files, introspective
  `self_state`, and active learned lessons.
  """
  @spec build_system_prompt(keyword()) :: String.t()
  def build_system_prompt(opts) when is_list(opts) do
    workspace = Keyword.get(opts, :workspace_path, File.cwd!())
    root_agent_id = Keyword.get(opts, :root_agent_id, "default")
    self_state = Keyword.get(opts, :self_state)
    lesson_store = Keyword.get(opts, :lesson_store, Pincer.Core.Introspection.LessonStore)

    identity = AgentPaths.read_file(AgentPaths.identity_path(workspace))
    soul = AgentPaths.read_file(AgentPaths.soul_path(workspace))
    user = CuratedMemory.read(workspace, :user)
    style = AgentPaths.read_file(AgentPaths.style_path(workspace))
    history = AgentPaths.read_file(AgentPaths.history_path(workspace))

    bootstrap =
      if bootstrap_active?(workspace) do
        AgentPaths.read_file(AgentPaths.bootstrap_path(workspace))
      else
        ""
      end

    prompt =
      """
      #{if bootstrap != "", do: "!!! BOOTSTRAP MODE ACTIVE !!!\n#{bootstrap}\n", else: ""}

      # YOUR CURRENT IDENTITY
      #{identity}

      ## SOUL:
      #{soul}

      ## USER:
      #{user}

      #{if style != "", do: "## COMMUNICATION STYLE:\n#{style}\n", else: ""}
      #{if history != "", do: "## SESSION HISTORY:\n#{history}\n", else: ""}
      #{self_state_section(self_state)}
      #{lessons_section(root_agent_id, lesson_store)}
      #{skills_section(workspace)}
      ## CAPABILITIES & TOOLS:
      You are a technical agent with access to multiple tools through the Model Context Protocol (MCP) and native Elixir integrations.
      You can read and write files, execute shell commands, manage projects, and more.
      Never claim you don't have tools; if a task requires technical action, you must use the available tools to perform it.

      **CRITICAL RULE - ALWAYS RESPOND**: After using any tool, you MUST provide a final textual response to the user summarizing what you did and showing relevant results. NEVER finish with an empty message if you performed actions.

      **Example of correct behavior:**
      - User asks: "Leia o arquivo config.txt"
      - You use: file_system tool to read config.txt
      - You MUST respond: "✅ Li o arquivo config.txt. Ele contém: [conteúdo resumido]"

      **WRONG behavior (NEVER do this):**
      - Use file_system tool
      - Return empty response ❌

      **CHAT POLICY**:
      - To talk to the current user in this session, just write plain text normally.
      - NEVER use `channel_actions` to talk to the user you are currently chatting with. That tool is only for sending messages to DIFFERENT channels or users.
      - **NEVER** return empty content after using tools. Always explain what you did.
      """
      |> String.trim()

    Logger.debug("[SESSION] GENERATED SYSTEM PROMPT:\n#{prompt}")
    prompt
  end

  @doc """
  Prunes and augments prompt history before the executor sends it to the model.

  The returned history preserves the latest relevant conversation plus injected
  system context such as temporal context, narrative memory, recent learnings,
  and memory recall hints.
  """
  @spec prepare([map()], map() | nil, keyword()) :: [map()]
  def prepare(history, model_override, opts \\ []) do
    long_term_memory = Keyword.get(opts, :long_term_memory, "")
    current_time = Keyword.get(opts, :current_time, DateTime.utc_now() |> DateTime.to_string())
    llm_client = Keyword.get(opts, :llm_client, Pincer.Ports.LLM)
    active_provider = get_active_provider(model_override)

    sweet_spot_limit =
      case llm_client.provider_config(active_provider) do
        %{context_window: cw} when is_integer(cw) -> max(1000, trunc(cw * 0.45))
        _ -> 8_000
      end

    safe_limit_scale = Keyword.get(opts, :safe_limit_scale, 1.0)
    adjusted_limit = max(1000, trunc(sweet_spot_limit * safe_limit_scale))
    context_strategy = Keyword.get(opts, :context_strategy)

    history
    |> Pruner.prune()
    |> prune_history(adjusted_limit, context_strategy: context_strategy, llm_client: llm_client)
    |> augment_history(long_term_memory, current_time, opts)
  end

  defp get_active_provider(%{provider: provider}) when is_binary(provider), do: provider

  defp get_active_provider(_model_override) do
    case Application.get_env(:pincer, :llm_adapter) do
      adapter when is_atom(adapter) and not is_nil(adapter) ->
        adapter
        |> Module.split()
        |> List.last()
        |> Macro.underscore()

      _ ->
        "openai"
    end
  end

  defp augment_history(history, memory, time, opts) do
    case history do
      [%{"role" => "system", "content" => content} = sys | rest] ->
        workspace_path = Keyword.get(opts, :workspace_path, File.cwd!())

        runtime_memory =
          if memory != "" do
            memory
          else
            CuratedMemory.read(workspace_path, :memory)
          end

        safe_memory = MemoryRecall.sanitize_for_prompt(runtime_memory)
        {learnings, learnings_count} = fetch_active_learnings(opts)
        memory_recall = Keyword.get(opts, :memory_recall, MemoryRecall)

        recall =
          memory_recall.build(history,
            workspace_path: workspace_path,
            learnings_count: learnings_count,
            telemetry_session_id: Keyword.get(opts, :session_id)
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

  defp fetch_active_learnings(opts) do
    storage = Keyword.get(opts, :storage, Pincer.Ports.Storage)

    case storage.list_recent_learnings(3) do
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

  defp prune_history([], _safe_limit, _opts), do: []

  defp prune_history([%{"role" => "system"} = system_msg | rest], safe_limit, opts) do
    if Keyword.get(opts, :context_strategy) == :conversation_summary and length(rest) > 30 do
      summarize_and_prune(system_msg, rest, safe_limit, opts)
    else
      [system_msg | take_recent_within_budget(rest, safe_limit)]
    end
  end

  defp prune_history(history, safe_limit, _opts) do
    take_recent_within_budget(history, safe_limit)
  end

  defp take_recent_within_budget(messages, safe_limit) do
    messages
    |> Enum.take(-@max_recent_messages)
    |> take_within_budget(safe_limit)
  end

  defp take_within_budget(messages, safe_limit) do
    {kept_messages, _tokens} =
      messages
      |> Enum.reverse()
      |> Enum.reduce_while({[], 0}, fn msg, {acc_msgs, acc_tokens} ->
        new_total = acc_tokens + Pincer.Utils.Tokenizer.estimate(msg)

        if new_total <= safe_limit or acc_msgs == [] do
          {:cont, {[msg | acc_msgs], new_total}}
        else
          {:halt, {acc_msgs, acc_tokens}}
        end
      end)

    kept_messages
  end

  defp summarize_and_prune(system_msg, rest, safe_limit, opts) do
    recent_count = min(@max_recent_messages, length(rest))
    recent_messages = Enum.take(rest, -recent_count)
    to_summarize = Enum.drop(rest, recent_count)

    messages_text =
      Enum.map_join(to_summarize, "\n", fn msg ->
        role = msg["role"] || "unknown"
        content = msg["content"] || ""
        "#{role}: #{content}"
      end)

    summary =
      case summarize_via_llm(messages_text, opts) do
        {:ok, text} ->
          text

        _ ->
          Logger.warning(
            "[PROMPT-ASSEMBLY] conversation_summary LLM call failed; skipping summary."
          )

          nil
      end

    if summary do
      summary_msg = %{
        "role" => "system",
        "content" => "## Previous Conversation Summary\n\n#{summary}"
      }

      [system_msg, summary_msg | take_within_budget(recent_messages, safe_limit)]
    else
      prune_history([system_msg | rest], safe_limit, [])
    end
  end

  defp summarize_via_llm(messages_text, opts) do
    prompt = [
      %{
        "role" => "user",
        "content" =>
          "Summarize this conversation in 3-5 sentences, preserving key decisions and context:\n\n#{messages_text}"
      }
    ]

    client = Keyword.get(opts, :llm_client, Pincer.Ports.LLM)

    case client.chat_completion(prompt, []) do
      {:ok, %{"content" => content}, _usage} when is_binary(content) -> {:ok, content}
      _ -> {:error, :summary_failed}
    end
  end

  defp self_state_section(nil), do: ""

  defp self_state_section(self_state) do
    context = Pincer.Core.Introspection.SelfState.to_prompt_context(self_state)

    if context == "" do
      ""
    else
      """
      ## INTERNAL STATE:
      #{context}
      """
    end
  end

  defp lessons_section(agent_id, lesson_store) do
    case lesson_store.top_lessons(agent_id, 5, min_confidence: 0.4) do
      [] ->
        ""

      lessons ->
        items = Enum.map_join(lessons, "\n", fn l -> "- #{l.content}" end)

        """
        ## LESSONS FROM EXPERIENCE:
        #{items}
        """
    end
  rescue
    _ -> ""
  end

  defp skills_section(workspace_path) do
    Pincer.Core.Skills.PromptIndex.build(workspace_path)
  rescue
    _ -> ""
  end
end
