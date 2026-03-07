defmodule Pincer.Utils.CodeSkeleton do
  @moduledoc """
  Extracts structural skeletons from source code (functions, modules, imports, classes)
  while stripping out implementation details to save up to 98% context window tokens.
  """

  @doc """
  Compresses source code into its structural skeleton based on file extension.
  """
  @spec extract(String.t(), String.t()) :: String.t()
  def extract(source_code, extension) do
    lines = String.split(source_code, ~r/\r?\n/)

    case String.downcase(extension) do
      ext when ext in [".ex", ".exs", ".gleam"] ->
        extract_elixir_like(lines)

      ext when ext in [".ts", ".js", ".java", ".c", ".cpp", ".cs", ".go", ".rs", ".zig"] ->
        extract_brace_based(lines)

      ext when ext in [".py"] ->
        extract_python(lines)

      # Fallback to raw if unsupported
      _ ->
        source_code
    end
  end

  defp extract_elixir_like(lines) do
    lines
    |> Enum.filter(fn line ->
      trimmed = String.trim(line)
      # Keep structural declarations
      String.starts_with?(trimmed, "defmodule ") or
        String.starts_with?(trimmed, "def ") or
        String.starts_with?(trimmed, "defp ") or
        String.starts_with?(trimmed, "defmacro ") or
        String.starts_with?(trimmed, "alias ") or
        String.starts_with?(trimmed, "import ") or
        String.starts_with?(trimmed, "require ") or
        String.starts_with?(trimmed, "use ") or
        String.starts_with?(trimmed, "pub ") or
        String.starts_with?(trimmed, "opaque ") or
        String.starts_with?(trimmed, "type ") or
        String.starts_with?(trimmed, "@spec ") or
        String.starts_with?(trimmed, "@type ") or
        String.starts_with?(trimmed, "@typep ") or
        String.starts_with?(trimmed, "@opaque ") or
        String.starts_with?(trimmed, "@callback ") or
        String.starts_with?(trimmed, "@macrocallback ") or
        String.starts_with?(trimmed, "schema ") or
        String.starts_with?(trimmed, "field ") or
        String.starts_with?(trimmed, "belongs_to ") or
        String.starts_with?(trimmed, "has_many ") or
        String.starts_with?(trimmed, "has_one ")
    end)
    |> Enum.map(fn line ->
      # Remove one-line 'do:' implementation
      line = Regex.replace(~r/,\s*do:\s*.*$/, line, "")

      # Remove trailing 'do'
      if String.contains?(line, "def") and String.ends_with?(String.trim(line), "do") do
        line |> String.trim_trailing() |> String.replace_suffix(" do", "")
      else
        line
      end
    end)
    |> Enum.join("\n")
  end

  defp extract_brace_based(lines) do
    lines
    |> Enum.reduce({[], 0}, fn line, {acc, brace_depth} ->
      trimmed = String.trim(line)

      # Track braces
      open_braces = length(Regex.scan(~r/\{/, line))
      close_braces = length(Regex.scan(~r/\}/, line))

      is_declaration? =
        String.starts_with?(trimmed, "import ") or
          String.starts_with?(trimmed, "export ") or
          String.starts_with?(trimmed, "class ") or
          String.starts_with?(trimmed, "interface ") or
          String.starts_with?(trimmed, "type ") or
          String.starts_with?(trimmed, "func ") or
          String.starts_with?(trimmed, "struct ") or
          String.starts_with?(trimmed, "impl ") or
          String.starts_with?(trimmed, "pub ") or
          String.starts_with?(trimmed, "fn ") or
          String.starts_with?(trimmed, "constructor") or
          Regex.match?(~r/^(public|private|protected|async|static)?\s*\w+\s*\(/, trimmed)

      # We keep declarations that are at depth 0 (or 1 for class methods)
      acc =
        if is_declaration? and brace_depth <= 1 do
          # Keep the line but strip implementation if it starts here
          if !String.starts_with?(trimmed, "import") and String.contains?(line, "{") do
            clean_line = line |> String.split("{") |> List.first() |> String.trim_trailing()
            [clean_line | acc]
          else
            [line | acc]
          end
        else
          acc
        end

      {acc, max(0, brace_depth + open_braces - close_braces)}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.join("\n")
  end

  defp extract_python(lines) do
    lines
    |> Enum.filter(fn line ->
      trimmed = String.trim(line)

      String.starts_with?(trimmed, "import ") or
        String.starts_with?(trimmed, "from ") or
        String.starts_with?(trimmed, "class ") or
        String.starts_with?(trimmed, "def ") or
        String.starts_with?(trimmed, "@")
    end)
    |> Enum.map(fn line ->
      String.replace_suffix(line, ":", "")
    end)
    |> Enum.join("\n")
  end
end
