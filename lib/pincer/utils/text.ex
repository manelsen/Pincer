defmodule Pincer.Utils.Text do
  @moduledoc """
  OpenClaw-inspired text sanitization and utility functions for Pincer.
  Handles stripping of internal scaffolding tags while preserving content within code blocks.
  """

  @internal_tags [
    "think",
    "thinking",
    "thought",
    "antthinking",
    "relevant-memories",
    "relevant_memories",
    "final"
  ]

  @doc """
  Strips all assistant internal scaffolding (thinking tags, memory tags, etc.)
  from the given text, unless they are inside fenced code blocks.
  """
  def strip_internal_scaffolding(nil), do: nil

  def strip_internal_scaffolding(text) do
    code_regions = find_code_regions(text)

    # 1. Strip reasoning/thinking tags
    cleaned =
      Enum.reduce(@internal_tags, text, fn tag, acc ->
        acc
        |> strip_tag_block_outside_code(tag, code_regions)
        |> strip_tag_outside_code(tag, code_regions)
      end)

    # 2. Strip downgraded tool call markers (Gemini style)
    # Example: [Tool Call: name (ID: ...)]
    cleaned
    |> String.replace(~r/\[Tool (?:Call|Result)[^\]]*\]/i, "")
    |> String.replace(~r/\[Historical context:[^\]]*\]/i, "")
    |> String.trim()
  end

  @doc """
  Removes user-invisible reasoning blocks from a response while preserving
  the externally visible answer text.
  """
  def strip_reasoning(nil), do: nil

  def strip_reasoning(text) when is_binary(text) do
    text
    |> String.replace(~r/<(?:thought|thinking)\b[^>]*>[\s\S]*?<\/(?:thought|thinking)>/i, "")
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

  @doc """
  Identifies indices of fenced code blocks (``` ... ```) to avoid stripping content inside them.
  Returns a list of {start_index, end_index} tuples.
  """
  def find_code_regions(text) do
    Regex.scan(~r/```.*?```/s, text, return: :index)
    |> Enum.map(fn [{start, len}] -> {start, start + len} end)
  end

  def inside_code?(index, regions) do
    Enum.any?(regions, fn {start, stop} -> index >= start and index < stop end)
  end

  defp strip_tag_outside_code(text, tag, regions) do
    # Match <tag...>, </tag>, or <tag...>content</tag>
    # We use a broad regex to catch as much scaffolding as possible
    regex = Regex.compile!("<\\s*\\/?\\s*#{tag}\\b[^<>]*>?", [:caseless, :multiline])

    # We need to process from end to start to avoid index shifting
    matches =
      Regex.scan(regex, text, return: :index)
      |> Enum.map(fn [{start, len}] -> {start, len} end)
      |> Enum.reject(fn {start, _len} -> inside_code?(start, regions) end)
      |> Enum.reverse()

    Enum.reduce(matches, text, fn {start, len}, acc ->
      String.slice(acc, 0, start) <> String.slice(acc, start + len..-1//1)
    end)
  end

  defp strip_tag_block_outside_code(text, tag, regions) do
    regex = Regex.compile!("<\\s*#{tag}\\b[^>]*>[\\s\\S]*?<\\s*/\\s*#{tag}\\s*>", "i")

    matches =
      Regex.scan(regex, text, return: :index)
      |> Enum.map(fn [{start, len}] -> {start, len} end)
      |> Enum.reject(fn {start, _len} -> inside_code?(start, regions) end)
      |> Enum.reverse()

    Enum.reduce(matches, text, fn {start, len}, acc ->
      String.slice(acc, 0, start) <> String.slice(acc, start + len..-1//1)
    end)
  end

  defp reasoning_block_html([_full, body]), do: reasoning_block_html(body)

  defp reasoning_block_html(body) when is_binary(body) do
    escaped =
      body
      |> String.trim()
      |> html_escape()

    "<b>💭 Reasoning</b>\n<pre>#{escaped}</pre>"
  end

  defp html_escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  @doc """
  Extracts XML-style tool calls while respecting code blocks.
  """
  def extract_xml_tool_calls(content, regions \\ nil)

  def extract_xml_tool_calls(nil, _), do: {nil, []}

  def extract_xml_tool_calls(content, regions) do
    regions = regions || find_code_regions(content)

    # Support <function=NAME> and <tool_call> formats
    # Uses a lookahead to allow multiple calls in one message without mandatory closing tags if at EOF
    regex = ~r/<(?:function=([a-zA-Z0-9_-]+)|tool_call)>(.*?)(?=<function=|<tool_call>|$|<\/function>|<\/tool_call>)/is
    matches = Regex.scan(regex, content, return: :index)

    {clean_text, tool_calls} =
      matches
      |> Enum.map(fn
        [full, {n_start, n_len}, body] when n_start != -1 ->
          {full, {n_start, n_len}, body}

        [full, _skipped_name_group, body] ->
          {full, nil, body}
      end)
      # Reject if the START of the tag is inside a code block
      |> Enum.reject(fn {{start, _}, _, _} -> inside_code?(start, regions) end)
      |> Enum.reverse()
      |> Enum.reduce({content, []}, fn {{start, len}, name_idx, {b_start, b_len}},
                                       {acc_text, acc_calls} ->
        body = String.slice(content, b_start, b_len)
        args = parse_xml_parameters(body)

        name =
          if name_idx do
            {n_start, n_len} = name_idx
            String.slice(content, n_start, n_len)
          else
            infer_tool_name(args)
          end

        call = %{
          "id" => "call_tx_" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)),
          "type" => "function",
          "function" => %{
            "name" => name,
            "arguments" => Jason.encode!(args)
          }
        }

        # Remove the tag from the text
        new_text =
          String.slice(acc_text, 0, start) <> String.slice(acc_text, start + len..-1//1)

        {new_text, [call | acc_calls]}
      end)

    # Final cleanup of any stray </function>, </tool_call> or </parameter> tags outside code
    final_text = strip_stray_xml_closers(clean_text, regions)

    {final_text, tool_calls}
  end

  defp parse_xml_parameters(body) do
    # Support both <parameter=NAME> and <parameter name="NAME"> formats
    param_regex = ~r/<parameter(?:=|\s+name="?)([a-zA-Z0-9_-]+)"?>(.*?)<\/parameter>/is

    Regex.scan(param_regex, body)
    |> Enum.reduce(%{}, fn [_, key, val], acc ->
      Map.put(acc, key, String.trim(val))
    end)
  end

  # Infers what Pincer tool best matches the provided parameter payload
  # Consistent with ToolParser logic
  defp infer_tool_name(params) do
    cond do
      Map.has_key?(params, "command") -> "safe_shell"
      anchored_edit_payload?(params) -> "file_system"
      Map.has_key?(params, "path") and Map.has_key?(params, "content") -> "file_system"
      Map.has_key?(params, "path") -> "file_system"
      true -> "unknown_tool"
    end
  end

  defp anchored_edit_payload?(params) do
    Map.has_key?(params, "path") and Map.has_key?(params, "anchor") and
      Map.has_key?(params, "content")
  end

  defp strip_stray_xml_closers(text, regions) do
    # Regex for </function> or </parameter> or </think> etc
    regex = ~r/<\s*\/\s*(?:function|tool_call|parameter|think|thinking|thought|antthinking|final)\b[^<>]*>/i

    matches =
      Regex.scan(regex, text, return: :index)
      |> Enum.map(fn [{start, len}] -> {start, len} end)
      |> Enum.reject(fn {start, _len} -> inside_code?(start, regions) end)
      |> Enum.reverse()

    Enum.reduce(matches, text, fn {start, len}, acc ->
      String.slice(acc, 0, start) <> String.slice(acc, start + len..-1//1)
    end)
  end
end
