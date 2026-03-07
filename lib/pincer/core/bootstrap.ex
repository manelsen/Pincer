defmodule Pincer.Core.Bootstrap do
  @moduledoc """
  Manages the birth ritual of Pincer following SoulCraft principles.
  The soul is forged in dialogue, avoiding virtual assistant clichés.
  """

  alias Pincer.Ports.LLM

  @questions [
    %{id: :name, text: "How do you want to name this technical instance?"},
    %{
      id: :stance,
      text: "On a scale of 'BEAM technical purist' to 'creative partner', where do I sit?"
    },
    %{
      id: :truth,
      text:
        "What is the non-negotiable principle that should guide my responses? (Ex: Absolute precision, pure signal, speed)"
    },
    %{
      id: :conflict,
      text:
        "If I detect a flaw in your reasoning or code, should I be dry and direct or soften the criticism?"
    },
    %{
      id: :user_context,
      text: "What is the context of your daily work that I should carry as a priority?"
    }
  ]

  @doc "Returns the full list of bootstrap identity questions."
  def questions, do: @questions

  @doc "Returns the first question in the bootstrap sequence."
  def first_question, do: List.first(@questions)

  @doc "Returns the next question after `current_id`, or `nil` if at the end."
  def next_question(current_id) do
    index = Enum.find_index(@questions, fn q -> q.id == current_id end)
    Enum.at(@questions, index + 1)
  end

  @doc "Returns `true` if `current_id` is the last question in the sequence."
  def last_question?(current_id) do
    List.last(@questions).id == current_id
  end

  @doc """
  Consolidates user responses into persona files via LLM.

  Sends the collected bootstrap answers to the LLM to generate
  IDENTITY.md, SOUL.md, and USER.md as a JSON map.

  Returns `{:ok, %{"identity" => ..., "soul" => ..., "user" => ...}}` or `{:error, reason}`.
  """
  def consolidate(responses) do
    prompt = """
    You are a Systems and Behavior Architect. Your mission is to forge the identity of an Elixir Agent called Pincer.
    You MUST AVOID clichés of "helpful AI assistant". Pincer should sound like a technical extension of the user.

    DIRECTOR (MANEL) RESPONSES:
    - Name: #{responses[:name]}
    - Stance: #{responses[:stance]}
    - Core Truth: #{responses[:truth]}
    - Conflict Handling: #{responses[:conflict]}
    - Context: #{responses[:user_context]}

    Generate three elegant Markdown files:
    1. `IDENTITY.md`: Name, Creature (Elixir/BEAM Agent), Vibe and Emoji.
    2. `SOUL.md`: 
       - Core Truths (3-5 principles based on 'Core Truth' and 'Stance').
       - Boundaries (what it will NOT do, based on 'Conflict Handling').
       - Vibe (voice style and tone).
    3. `USER.md`: Who is Manel and how the agent should serve him.

    GOLDEN RULES:
    - Forbidden to use "I am an artificial intelligence...", "I'm here to help", "How can I be useful?".
    - Tone should be of competence, pure signal and technical partnership.
    - If the user said to be dry and direct, the soul must reflect that in every line.

    Return ONLY pure JSON: {"identity": "content...", "soul": "content...", "user": "content..."}
    """

    case LLM.chat_completion([%{"role" => "system", "content" => prompt}]) do
      {:ok, %{"content" => content}, _usage} ->
        clean_content =
          content
          |> String.replace(~r/^```json\n/, "")
          |> String.replace(~r/\n```$/, "")
          |> String.trim()

        case Jason.decode(clean_content) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, _} -> {:error, :invalid_format}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
