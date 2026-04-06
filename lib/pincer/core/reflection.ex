defmodule Pincer.Core.Reflection do
  @moduledoc """
  Trace-based reflection policy for proactive follow-ups.

  Provides two levels of reflection:

  - **Lightweight** (`classify/1`, `next_prompt/2`): Pure logic, no LLM call.
    Classifies traces and returns canned prompts.

  - **Deep** (`reflect/3`): Calls the introspection LLM to produce a
    structured self-state update. Uses `classify/1` as a gate to avoid
    unnecessary LLM calls on shallow traces.
  """

  alias Pincer.Core.Introspection.Client, as: IntrospectionClient
  alias Pincer.Core.Introspection.Mood
  alias Pincer.Core.Introspection.Schema

  @min_steps 3

  # --- Lightweight classification (no LLM call) ---

  @spec classify(map()) :: :success | :failure | :tool_heavy | :shallow
  def classify(%{"trace" => trace}) when is_map(trace), do: classify(trace)
  def classify(%{trace: trace}) when is_map(trace), do: classify(trace)
  def classify(%{"steps" => steps}) when is_list(steps), do: classify(%{steps: steps})

  def classify(%{steps: steps}) when is_list(steps) do
    error? = Enum.any?(steps, &(step_kind(&1) == "error"))
    tool_count = Enum.count(steps, &(step_kind(&1) == "tool"))

    cond do
      error? -> :failure
      tool_count >= 3 -> :tool_heavy
      length(steps) < @min_steps -> :shallow
      true -> :success
    end
  end

  def classify(_), do: :shallow

  @spec next_prompt(map(), keyword()) :: {:ok, String.t()} | :ignore
  def next_prompt(trace_metadata, _opts \\ [])

  def next_prompt(trace_metadata, opts) when is_map(trace_metadata) and is_list(opts) do
    case classify(trace_metadata) do
      :failure ->
        {:ok,
         "Faça uma auto-reflexão curta sobre a última falha e proponha a próxima ação segura."}

      :tool_heavy ->
        {:ok,
         "Resuma as etapas com ferramentas da última execução e proponha simplificação do plano."}

      :success ->
        if Keyword.get(opts, :allow_success_reflection, false) do
          {:ok, "Faça uma checagem rápida: o resultado final atende completamente ao objetivo?"}
        else
          :ignore
        end

      :shallow ->
        :ignore
    end
  end

  def next_prompt(_, _), do: :ignore

  # --- Deep reflection (introspection LLM call) ---

  @doc """
  Performs LLM-powered reflection on a trace, producing a structured
  self-state update.

  Uses `classify/1` as a gate: shallow traces are skipped without an
  LLM call. For non-shallow traces, calls the introspection LLM and
  parses the JSON response.

  ## Options

    - `:introspection_client` — module implementing `chat_completion/2`
      (default: `Pincer.Core.Introspection.Client`)
  """
  @spec reflect(map(), Schema.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def reflect(trace_metadata, self_state, opts \\ [])

  def reflect(trace_metadata, %Schema{} = self_state, opts) do
    case classify(trace_metadata) do
      :shallow ->
        {:ok, %{action: :skip}}

      _classification ->
        client = Keyword.get(opts, :introspection_client, IntrospectionClient)
        messages = build_reflection_prompt(trace_metadata, self_state)

        case client.chat_completion(messages, []) do
          {:ok, %{"content" => content}, _usage} ->
            {:ok, parse_reflection_response(content)}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc """
  Builds the prompt messages for the introspection LLM.

  Returns a list with a system message (instructions) and a user message
  (serialized self-state + trace + classification).
  """
  @spec build_reflection_prompt(map(), Schema.t()) :: [map()]
  def build_reflection_prompt(trace_metadata, %Schema{} = self_state) do
    classification = classify(trace_metadata)

    system_msg = """
    You are the introspection engine of an AI agent. Given the agent's \
    current internal state and its last execution trace, produce a JSON \
    object with these keys:
    - "focus": string — what the agent should focus on next (1 sentence)
    - "concerns": array of strings — up to 4 active concerns
    - "open_questions": array of strings — up to 3 questions to investigate
    - "summary": string — 1-2 sentence reflection on the last execution
    - "mood_valence": float between -1.0 and 1.0 (current emotional direction)
    - "mood_arousal": float between 0.0 and 1.0 (current activation level)

    Respond ONLY with the JSON object, no markdown fences.
    """

    mood_label = Mood.label(self_state.mood_valence || 0.0, self_state.mood_arousal || 0.0)

    user_msg = """
    ## Current Self-State
    - Wakefulness: #{self_state.wakefulness}
    - Focus: #{self_state.focus || "none"}
    - Concerns: #{inspect(self_state.concerns || [])}
    - Open Questions: #{inspect(self_state.open_questions || [])}
    - Last Reflection: #{self_state.last_reflection_summary || "none"}
    - Mood: #{mood_label} (valence=#{self_state.mood_valence || 0.0}, arousal=#{self_state.mood_arousal || 0.0})

    ## Execution Trace
    - Classification: #{classification}
    - Steps: #{inspect(extract_steps(trace_metadata))}
    """

    [
      %{"role" => "system", "content" => String.trim(system_msg)},
      %{"role" => "user", "content" => String.trim(user_msg)}
    ]
  end

  # --- Private helpers ---

  defp step_kind(%{"kind" => kind}), do: to_string(kind)
  defp step_kind(%{kind: kind}), do: to_string(kind)
  defp step_kind(_), do: ""

  defp extract_steps(%{steps: steps}) when is_list(steps), do: steps
  defp extract_steps(%{"steps" => steps}) when is_list(steps), do: steps
  defp extract_steps(%{"trace" => %{"steps" => steps}}) when is_list(steps), do: steps
  defp extract_steps(%{"trace" => %{steps: steps}}) when is_list(steps), do: steps
  defp extract_steps(_), do: []

  defp parse_reflection_response(content) when is_binary(content) do
    case Jason.decode(content) do
      {:ok,
       %{"focus" => focus, "concerns" => concerns, "open_questions" => oq, "summary" => s} = full} ->
        %{
          focus: focus,
          concerns: Enum.take(List.wrap(concerns), 4),
          open_questions: Enum.take(List.wrap(oq), 3),
          summary: s,
          last_reflection_summary: s
        }
        |> maybe_merge_mood(full)

      {:ok, %{"summary" => s} = partial} ->
        %{
          summary: s,
          last_reflection_summary: s
        }
        |> maybe_merge(:focus, partial["focus"])
        |> maybe_merge(:concerns, partial["concerns"])
        |> maybe_merge(:open_questions, partial["open_questions"])
        |> maybe_merge_mood(partial)

      _ ->
        %{summary: content, last_reflection_summary: content}
    end
  end

  defp maybe_merge(map, _key, nil), do: map
  defp maybe_merge(map, key, value), do: Map.put(map, key, value)

  defp maybe_merge_mood(map, %{"mood_valence" => v, "mood_arousal" => a})
       when is_number(v) and is_number(a) do
    Map.merge(map, %{mood_valence: v / 1, mood_arousal: a / 1})
  end

  defp maybe_merge_mood(map, _), do: map
end
