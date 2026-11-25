defmodule Pincer.Core.Executor.TurnOutcomePolicy do
  @moduledoc """
  Pure policy for deciding the user-visible outcome of a completed assistant turn.

  This keeps "what should the user receive?" separate from executor recursion,
  tool execution, and channel transport concerns.
  """

  alias Pincer.Utils.Text

  @type outcome ::
          {:final_text, String.t()}
          | {:tool_only, [map()]}
          | {:error, :empty_response}

  @doc """
  Merges streamed content and reasoning without leaking reasoning-only output.
  """
  @spec merge_reasoning_and_content(String.t(), String.t()) :: String.t()
  def merge_reasoning_and_content("", ""), do: ""
  def merge_reasoning_and_content(content, "") when is_binary(content), do: content

  def merge_reasoning_and_content(content, reasoning)
      when is_binary(content) and is_binary(reasoning) do
    cond do
      String.trim(reasoning) == "" -> content
      String.trim(content) != "" -> content
      true -> ""
    end
  end

  @doc """
  Returns `true` when `text` contains no visible characters outside reasoning tags.
  """
  @spec reasoning_only?(term()) :: boolean()
  def reasoning_only?(text) when is_binary(text) do
    text
    |> Text.strip_reasoning()
    |> to_string()
    |> String.trim() == ""
  end

  def reasoning_only?(_text), do: false

  @spec resolve(map()) :: outcome()
  def resolve(attrs) when is_map(attrs) do
    final_text = visible_text(Map.get(attrs, :final_text))
    streamed_text = visible_text(Map.get(attrs, :streamed_text))
    tool_messages = Map.get(attrs, :tool_messages, [])

    cond do
      final_text != nil ->
        {:final_text, final_text}

      streamed_text != nil ->
        {:final_text, streamed_text}

      tool_messages != [] ->
        {:tool_only, tool_messages}

      true ->
        {:error, :empty_response}
    end
  end

  defp visible_text(nil), do: nil

  defp visible_text(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp visible_text(other), do: other |> to_string() |> visible_text()
end
