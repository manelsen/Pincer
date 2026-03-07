defmodule Pincer.LLM.ToolParser do
  @moduledoc """
  A polymorphic parser for extracting tool calls from varying LLM response formats.

  Some models (like OpenAI) return a natively structured `tool_calls` JSON list.
  Other models (like Minimax, Llama, or Claude before tool support) might hallucinate
  tool calls as raw XML or JSON within the message `content`.

  This module applies a chain of parsers to extract, normalize, and strip
  these structures, returning a standard `assistant_msg` map compatible with Pincer's Executor.
  """

  @doc """
  Parses a raw assistant message map and extracts any inline tool calls,
  cleaning the remaining `content` text.

  Returns `%{assistant_msg | "content" => cleaned_content, "tool_calls" => parsed_tool_calls!}`
  """
  @spec parse(map()) :: map()
  def parse(assistant_msg) when is_map(assistant_msg) do
    # 1. Start with native tool calls if present
    native_calls = assistant_msg["tool_calls"] || []

    content = assistant_msg["content"] || ""

    # 2. Extract Minimax tool calls from content
    {content_after_minimax, minimax_calls} = extract_minimax_xml(content)

    # 3. Extract generic <tool_call> XML
    {cleaned_content, generic_calls} = extract_generic_xml(content_after_minimax)

    # 4. Combine all extracted calls
    all_calls = native_calls ++ minimax_calls ++ generic_calls

    final_calls =
      if all_calls == [] do
        nil
      else
        all_calls
        |> Enum.with_index()
        |> Enum.map(fn {call, index} ->
          call
          |> Map.put("id", call["id"] || "call_ext_#{index}_#{:os.system_time(:millisecond)}")
        end)
      end

    assistant_msg
    |> Map.put("content", if(cleaned_content == "", do: nil, else: String.trim(cleaned_content)))
    |> Map.put("tool_calls", final_calls)
  end

  defp extract_minimax_xml(content) do
    regex = ~r/<minimax:tool_call>([\s\S]*?)<\/minimax:tool_call>/i

    extracted =
      Regex.scan(regex, content)
      |> Enum.map(fn [_, inner_xml] ->
        parse_xml_parameters(inner_xml)
      end)
      |> Enum.reject(&is_nil/1)

    cleaned_content = Regex.replace(regex, content, "")

    {cleaned_content, extracted}
  end

  defp extract_generic_xml(content) do
    regex = ~r/<tool_call>([\s\S]*?)<\/tool_call>/i

    extracted =
      Regex.scan(regex, content)
      |> Enum.map(fn [_, inner_xml] ->
        parse_xml_parameters(inner_xml)
      end)
      |> Enum.reject(&is_nil/1)

    cleaned_content = Regex.replace(regex, content, "")

    {cleaned_content, extracted}
  end

  # Extremely naive but effective parsing for `<parameter name="XX">YY</parameter>`
  defp parse_xml_parameters(inner_xml) do
    param_regex = ~r/<parameter name="([^"]+)">([\s\S]*?)<\/parameter>/i

    params =
      Regex.scan(param_regex, inner_xml)
      |> Enum.into(%{}, fn [_, name, value] ->
        {String.trim(name), String.trim(value)}
      end)

    if map_size(params) > 0 do
      tool_name = infer_tool_name(params)

      %{
        "type" => "function",
        "function" => %{
          "name" => tool_name,
          "arguments" => Jason.encode!(params)
        }
      }
    else
      nil
    end
  end

  # Infers what Pincer tool best matches the provided parameter payload
  defp infer_tool_name(params) do
    cond do
      Map.has_key?(params, "command") -> "run_command"
      Map.has_key?(params, "path") and Map.has_key?(params, "content") -> "file_system"
      Map.has_key?(params, "path") -> "read_file"
      true -> "unknown_tool"
    end
  end
end
