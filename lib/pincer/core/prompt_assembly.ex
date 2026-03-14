defmodule Pincer.Core.PromptAssembly do
  @moduledoc """
  Builds prompt history for the executor by composing pruning and system-context augmentation.

  This module centralizes the non-transport prompt preparation logic so the
  executor loop only coordinates execution and recovery paths.
  """

  require Logger
  alias Pincer.Core.AgentPaths
  alias Pincer.Core.MemoryRecall

  @max_recent_messages 15

  @doc """
  Prunes and augments prompt history before the executor sends it to the model.

  The returned history preserves the latest relevant conversation plus injected
  system context such as temporal context, narrative memory, recent learnings,
  and memory recall hints.
  """
  @spec prepare([map()], map() | nil, keyword()) :: [map()]
  def prepare(history, model_override, opts \\ []) do
    long_term_memory = Keyword.get(opts, :long_term_memory, Process.get(:long_term_memory, ""))
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
        workspace_path =
          Keyword.get(opts, :workspace_path, Process.get(:workspace_path, File.cwd!()))

        runtime_memory =
          if memory != "" do
            memory
          else
            AgentPaths.read_file(AgentPaths.memory_path(workspace_path))
          end

        safe_memory = MemoryRecall.sanitize_for_prompt(runtime_memory)
        {learnings, learnings_count} = fetch_active_learnings(opts)
        memory_recall = Keyword.get(opts, :memory_recall, MemoryRecall)

        recall =
          memory_recall.build(history,
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
    if Keyword.get(opts, :context_strategy) == :conversation_summary and
         length(rest) > 30 do
      summarize_and_prune(system_msg, rest, safe_limit, opts)
    else
      recent_messages =
        if length(rest) > @max_recent_messages do
          Enum.drop(rest, length(rest) - @max_recent_messages)
        else
          rest
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

      [system_msg | kept_messages]
    end
  end

  defp prune_history(history, safe_limit, _opts) do
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

  defp summarize_and_prune(system_msg, rest, safe_limit, opts) do
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
end
