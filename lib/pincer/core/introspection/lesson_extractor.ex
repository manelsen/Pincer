defmodule Pincer.Core.Introspection.LessonExtractor do
  @moduledoc """
  Extracts reusable lessons from execution traces via the introspection LLM.

  After each non-trivial execution, the extractor sends the trace to the
  introspection LLM and asks for structured lessons. Each lesson is checked
  for novelty (Jaccard similarity) before being persisted to the store.
  """

  alias Pincer.Core.Introspection.Client, as: IntrospectionClient
  alias Pincer.Core.Introspection.LessonStore

  @doc """
  Extracts lessons from a trace and persists novel ones.

  Returns `{:ok, persisted_lessons}` where the list may be empty if all
  lessons were duplicates or the LLM returned nothing.

  ## Options
  - `:introspection_client` — injectable LLM module (default: `Introspection.Client`)
  """
  @spec extract(String.t(), map(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def extract(agent_id, trace_metadata, opts \\ []) do
    client = Keyword.get(opts, :introspection_client, IntrospectionClient)
    messages = build_extraction_prompt(trace_metadata)

    case client.chat_completion(messages, []) do
      {:ok, %{"content" => content}, _usage} ->
        lessons = parse_lessons(content)
        persisted = persist_novel(agent_id, lessons)
        {:ok, persisted}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_extraction_prompt(trace_metadata) do
    steps = extract_steps(trace_metadata)

    system_msg = """
    You are a lesson extraction engine for an AI agent. Given an execution \
    trace, extract reusable lessons the agent should remember for future \
    interactions. Each lesson should be a concise, actionable insight.

    Respond ONLY with a JSON object: {"lessons": [{"content": "...", "confidence": 0.0-1.0}]}

    Rules:
    - Extract 0-3 lessons per trace
    - Each lesson must be a single, specific, actionable insight
    - Set confidence based on how generally applicable the lesson is
    - If no meaningful lesson can be extracted, return {"lessons": []}
    - No markdown fences
    """

    user_msg = """
    ## Execution Trace
    Steps: #{inspect(steps)}
    """

    [
      %{"role" => "system", "content" => String.trim(system_msg)},
      %{"role" => "user", "content" => String.trim(user_msg)}
    ]
  end

  defp parse_lessons(content) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, %{"lessons" => lessons}} when is_list(lessons) ->
        Enum.filter(lessons, fn
          %{"content" => c} when is_binary(c) and c != "" -> true
          _ -> false
        end)

      _ ->
        []
    end
  end

  defp persist_novel(agent_id, lessons) do
    Enum.reduce(lessons, [], fn lesson_data, acc ->
      attrs = %{
        content: lesson_data["content"],
        extraction_confidence: lesson_data["confidence"] || 0.5,
        source: "reflection"
      }

      case LessonStore.create(agent_id, attrs) do
        {:ok, lesson} -> [lesson | acc]
        {:error, _} -> acc
      end
    end)
    |> Enum.reverse()
  end

  defp extract_steps(%{steps: steps}) when is_list(steps), do: steps
  defp extract_steps(%{"steps" => steps}) when is_list(steps), do: steps
  defp extract_steps(%{"trace" => %{"steps" => steps}}) when is_list(steps), do: steps
  defp extract_steps(_), do: []
end
