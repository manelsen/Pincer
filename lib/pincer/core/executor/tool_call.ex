defmodule Pincer.Core.Executor.ToolCall do
  @moduledoc """
  Normalization, argument decoding (with loose JSON salvage), spec sanitization,
  and human-readable formatting for LLM tool calls.
  """

  require Logger

  @doc """
  Removes internal underscore-prefixed keys recursively from tool schema specs.
  """
  @spec clean_specs(term()) :: term()
  def clean_specs(tools) when is_list(tools), do: Enum.map(tools, &clean_value/1)
  def clean_specs(other), do: other

  defp clean_value(map) when is_map(map) do
    map
    |> Enum.reject(fn {k, _v} -> k |> to_string() |> String.starts_with?("_") end)
    |> Map.new(fn {k, v} -> {k, clean_value(v)} end)
  end

  defp clean_value(list) when is_list(list), do: Enum.map(list, &clean_value/1)
  defp clean_value(other), do: other

  @doc """
  Ensures `"type" => "function"` is present on normalized tool call maps.
  """
  @spec ensure_type(map()) :: map()
  def ensure_type(call) when is_map(call), do: Map.put_new(call, "type", "function")

  @doc """
  Extracts `{call_id, name, raw_arguments}` from string- or atom-keyed tool calls.
  """
  @spec normalize(map()) :: {String.t(), String.t(), term()}
  def normalize(%{"id" => id, "function" => %{"name" => name, "arguments" => args}}),
    do: {id, name, args}

  def normalize(%{id: id, function: %{name: name, arguments: args}}),
    do: {id, name, args}

  def normalize(call) when is_map(call) do
    id = call["id"] || call[:id] || "call_unknown"
    f = call["function"] || call[:function] || %{}
    name = f["name"] || f[:name] || "unknown"
    args = f["arguments"] || f[:arguments] || "{}"
    {id, name, args}
  end

  @doc """
  Decodes tool call arguments from JSON string or map, falling back to loose
  partial-JSON salvage when truncated.
  """
  @spec parse_arguments(term()) :: map()
  def parse_arguments(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, args} when is_map(args) ->
        args

      {:ok, _other} ->
        %{}

      {:error, reason} ->
        salvaged = salvage_arguments(json)

        Logger.warning(
          "[EXECUTOR] Malformed tool arguments JSON#{if(salvaged == %{}, do: " (falling back to empty args)", else: " (salvaged partial args)")}: #{inspect(reason)} — raw: #{inspect(json)}"
        )

        salvaged
    end
  end

  def parse_arguments(args) when is_map(args), do: args
  def parse_arguments(_), do: %{}

  @doc """
  Formats a short human-readable description of a single tool call.
  """
  @spec describe(term()) :: String.t()
  def describe(tool_call) when is_map(tool_call) do
    {_id, name, raw_args} = normalize(tool_call)

    args =
      case raw_args do
        map when is_map(map) -> map
        json when is_binary(json) -> parse_arguments(json)
        _ -> %{}
      end

    summarize_call(name || "unknown", args)
  rescue
    _ -> tool_name(tool_call) || "unknown"
  end

  def describe(_), do: "unknown"

  @doc """
  Returns a comma-separated summary of tool names in `tool_calls`.
  """
  @spec names_summary([map()]) :: String.t()
  def names_summary(tool_calls) when is_list(tool_calls) do
    case tool_calls
         |> Enum.map(&tool_name/1)
         |> Enum.reject(&blank?/1)
         |> Enum.join(", ") do
      "" -> "unknown_tool"
      summary -> summary
    end
  end

  defp tool_name(call) when is_map(call) do
    get_in(call, ["function", "name"]) || get_in(call, [:function, :name])
  end

  defp tool_name(_), do: nil

  defp summarize_call("run_command", %{"command" => cmd}),
    do: "run_command: #{truncate(cmd, 70)}"

  defp summarize_call("file_system", %{"action" => action, "path" => path}),
    do: "file_system #{action}: #{truncate(path, 60)}"

  defp summarize_call("file_system", %{"action" => action}),
    do: "file_system: #{action}"

  defp summarize_call("read_file", %{"path" => path}),
    do: "read_file: #{truncate(path, 70)}"

  defp summarize_call("write_file", %{"path" => path}),
    do: "write_file: #{truncate(path, 70)}"

  defp summarize_call(name, args) when map_size(args) == 0, do: name

  defp summarize_call(name, args) do
    first_val = args |> Map.values() |> List.first() |> truncate(60)
    "#{name}: #{first_val}"
  end

  defp truncate(value, max), do: value |> to_string() |> Pincer.Utils.Text.truncate(max, "…")

  defp blank?(nil), do: true
  defp blank?(str) when is_binary(str), do: String.trim(str) == ""
  defp blank?(_), do: false

  # --- Loose JSON salvage parser ---

  defp salvage_arguments(json) do
    trimmed = String.trim(json)

    if String.starts_with?(trimmed, "{") do
      case parse_loose_object(trimmed) do
        {:ok, args} when map_size(args) > 0 -> args
        _ -> %{}
      end
    else
      %{}
    end
  end

  defp parse_loose_object("{" <> rest), do: parse_loose_members(rest, %{})
  defp parse_loose_object(_), do: :error

  defp parse_loose_members(binary, acc) do
    binary = String.trim_leading(binary)

    cond do
      binary == "" or String.starts_with?(binary, "}") ->
        {:ok, acc}

      true ->
        with {:ok, key, after_key} <- parse_loose_string(binary),
             after_key <- String.trim_leading(after_key),
             true <- String.starts_with?(after_key, ":"),
             {:ok, value, after_value} <-
               parse_loose_value(String.trim_leading(String.slice(after_key, 1..-1//1))),
             {:ok, next} <- parse_loose_separator(after_value) do
          parse_loose_members(next, Map.put(acc, key, value))
        else
          _ -> if(map_size(acc) > 0, do: {:ok, acc}, else: :error)
        end
    end
  end

  defp parse_loose_separator(binary) do
    binary = String.trim_leading(binary)

    cond do
      binary == "" -> {:ok, ""}
      String.starts_with?(binary, ",") -> {:ok, String.slice(binary, 1..-1//1)}
      String.starts_with?(binary, "}") -> {:ok, ""}
      true -> :error
    end
  end

  defp parse_loose_value("\"" <> _ = binary), do: parse_loose_string(binary)

  defp parse_loose_value(binary) do
    literal =
      binary
      |> String.split(~r/\s*(?:,|})/, parts: 2, trim: false)
      |> List.first()
      |> to_string()
      |> String.trim()

    cond do
      literal == "" ->
        :error

      literal == "true" ->
        {:ok, true, slice_after(binary, literal)}

      literal == "false" ->
        {:ok, false, slice_after(binary, literal)}

      literal == "null" ->
        {:ok, nil, slice_after(binary, literal)}

      Regex.match?(~r/^-?\d+$/, literal) ->
        {:ok, String.to_integer(literal), slice_after(binary, literal)}

      Regex.match?(~r/^-?\d+\.\d+$/, literal) ->
        {:ok, String.to_float(literal), slice_after(binary, literal)}

      true ->
        :error
    end
  end

  defp slice_after(binary, literal), do: String.slice(binary, byte_size(literal)..-1//1)

  defp parse_loose_string("\"" <> rest), do: parse_loose_chars(rest, [])
  defp parse_loose_string(_), do: :error

  defp parse_loose_chars(<<>>, acc),
    do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary(), ""}

  defp parse_loose_chars(<<"\"", rest::binary>>, acc),
    do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp parse_loose_chars(<<"\\", rest::binary>>, acc),
    do: parse_loose_escape(rest, acc)

  defp parse_loose_chars(<<char::utf8, rest::binary>>, acc),
    do: parse_loose_chars(rest, [<<char::utf8>> | acc])

  defp parse_loose_escape(<<>>, acc),
    do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary(), ""}

  defp parse_loose_escape(<<"\"", rest::binary>>, acc), do: parse_loose_chars(rest, ["\"" | acc])
  defp parse_loose_escape(<<"\\", rest::binary>>, acc), do: parse_loose_chars(rest, ["\\" | acc])
  defp parse_loose_escape(<<"/", rest::binary>>, acc), do: parse_loose_chars(rest, ["/" | acc])
  defp parse_loose_escape(<<"b", rest::binary>>, acc), do: parse_loose_chars(rest, ["\b" | acc])
  defp parse_loose_escape(<<"f", rest::binary>>, acc), do: parse_loose_chars(rest, ["\f" | acc])
  defp parse_loose_escape(<<"n", rest::binary>>, acc), do: parse_loose_chars(rest, ["\n" | acc])
  defp parse_loose_escape(<<"r", rest::binary>>, acc), do: parse_loose_chars(rest, ["\r" | acc])
  defp parse_loose_escape(<<"t", rest::binary>>, acc), do: parse_loose_chars(rest, ["\t" | acc])

  defp parse_loose_escape(<<"u", hex::binary-size(4), rest::binary>>, acc) do
    case Integer.parse(hex, 16) do
      {codepoint, ""} -> parse_loose_chars(rest, [<<codepoint::utf8>> | acc])
      _ -> parse_loose_chars(rest, ["u", hex | acc])
    end
  end

  defp parse_loose_escape(<<char::utf8, rest::binary>>, acc),
    do: parse_loose_chars(rest, [<<char::utf8>> | acc])
end
