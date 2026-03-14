defmodule Pincer.Core.ToolOnlyOutcomeFormatter do
  @moduledoc """
  Pure formatter for turns that used tools but did not produce a final assistant answer.

  This module keeps wording and summarization of degraded tool-only turns out of
  `TurnOutcomePolicy` and the executor control flow.
  """

  alias Pincer.Core.ToolResultSummary

  @max_tools 5
  @max_preview_chars 140

  @doc """
  Formats a user-visible partial response from tool messages.
  """
  @spec format([map()]) :: String.t()
  def format(tool_messages) when is_list(tool_messages) do
    useful_summaries? = Enum.any?(tool_messages, &(ToolResultSummary.summarize(&1) != nil))

    used_tools =
      tool_messages
      |> Enum.map(&(&1["name"] || "tool"))
      |> Enum.uniq()
      |> Enum.join(", ")

    tool_summary =
      tool_messages
      |> Enum.take(@max_tools)
      |> Enum.map(&format_tool_summary/1)
      |> Enum.join("\n")

    failure_notice =
      if Enum.any?(tool_messages, &tool_error?/1) do
        "Algumas ferramentas falharam ou retornaram dados limitados."
      else
        "As ferramentas rodaram, mas o assistente nao fechou a resposta final."
      end

    intro =
      if useful_summaries? do
        "Consegui obter dados pelas ferramentas, mas o assistente nao transformou isso numa resposta final."
      else
        "Nao consegui fechar uma resposta final para esta pergunta."
      end

    summary_label =
      if useful_summaries? do
        "Resumo util obtido das ferramentas:"
      else
        "Resumo parcial:"
      end

    """
    #{intro}
    #{failure_notice}
    Ferramentas utilizadas: #{used_tools}

    #{summary_label}
    #{tool_summary}

    Se quiser, tente reenviar a pergunta ou use /verbose on para mais contexto.
    """
    |> String.trim()
  end

  defp format_tool_summary(msg) do
    tool_name = msg["name"] || "tool"
    result_preview = ToolResultSummary.summarize(msg) || preview(msg["content"])
    "- #{tool_name}: #{result_preview}"
  end

  defp preview(nil), do: ""

  defp preview(content) when is_binary(content) do
    content
    |> String.split("\n")
    |> Enum.take(3)
    |> Enum.join(" ")
    |> String.slice(0, @max_preview_chars)
  end

  defp preview(other), do: other |> to_string() |> preview()

  defp tool_error?(%{"content" => content}) when is_binary(content) do
    down = String.downcase(content)
    String.starts_with?(down, "error:") or String.contains?(down, "fetch failed")
  end

  defp tool_error?(_msg), do: false
end
