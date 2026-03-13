defmodule Pincer.Core.TurnOutcomePolicy do
  @moduledoc """
  Pure policy for deciding the user-visible outcome of a completed assistant turn.

  This keeps "what should the user receive?" separate from executor recursion,
  tool execution, and channel transport concerns.
  """

  @type outcome ::
          {:final_text, String.t()} | {:tool_summary, String.t()} | {:error, :empty_response}

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
        {:tool_summary, build_tool_summary(tool_messages)}

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

  defp build_tool_summary(tool_messages) do
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
  end
end
