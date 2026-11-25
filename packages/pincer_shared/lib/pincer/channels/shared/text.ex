defmodule Pincer.Channels.Shared.Text do
  @moduledoc "Reasoning cleanup and HTML formatting for channel responses."

  @doc """
  Removes user-invisible reasoning blocks from a response while preserving
  the externally visible answer text.
  """
  def strip_reasoning(nil), do: nil

  def strip_reasoning(text) when is_binary(text) do
    text
    |> String.replace(~r/<(?:thought|thinking)\b[^>]*>[\s\S]*?<\/(?:thought|thinking)>/i, "")
    |> String.replace(~r/\A\s*<(?:thought|thinking)\b[^>]*>[\s\S]*\z/i, "")
    |> String.replace(~r/^think>.*?(?:\n\n|\r\n\r\n|$)/is, "")
    |> String.trim()
  end

  def strip_reasoning(other), do: other

  @doc """
  Formats reasoning blocks for HTML-capable channels while preserving the final answer.
  """
  def format_reasoning_html(nil), do: nil

  def format_reasoning_html(text) when is_binary(text) do
    text
    |> then(fn current ->
      Regex.replace(~r/<thought>([\s\S]*?)<\/thought>/i, current, &reasoning_block_html/1,
        global: true
      )
    end)
    |> then(fn current ->
      Regex.replace(~r/<thinking>([\s\S]*?)<\/thinking>/i, current, &reasoning_block_html/1,
        global: true
      )
    end)
    |> then(fn current ->
      Regex.replace(~r/^.*?think>\s*([\s\S]*)$/i, current, &reasoning_block_html/1)
    end)
  end

  def format_reasoning_html(other), do: other

  defp reasoning_block_html([_full, body]), do: reasoning_block_html(body)

  defp reasoning_block_html(body) when is_binary(body) do
    escaped =
      body
      |> String.trim()
      |> html_escape()

    "<b>💭 Reasoning</b>\n<i>#{escaped}</i>"
  end

  defp html_escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
