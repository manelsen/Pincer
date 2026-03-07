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
      ext when ext in [".ex", ".exs"] -> extract_elixir(lines)
      ext when ext in [".ts", ".js", ".java", ".c", ".cpp", ".cs", ".go", ".rs"] -> extract_brace_based(lines)
      ext when ext in [".py"] -> extract_python(lines)
      _ -> source_code # Fallback to raw if unsupported
    end
  end

  defp extract_elixir(lines) do
    # For Elixir, we want to keep `defmodule`, `def`, `defp`, `alias`, `require`, `import`, `use`, `@spec`, `@moduledoc`, `@doc`.
    # We strip the body inside `do ... end`.
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
      # Clean trailing " do" for functions/modules to make it purely a signature
      Regex.replace(~r/,\s*do:\s*.*$/, line, "")
      |> String.replace_suffix(" do", "")
    end)
    |> Enum.join("\n")
  end

  defp extract_brace_based(lines) do
    # For C-style, keep imports, exports, classes, interfaces, and function signatures.
    # A simple heuristic: if it contains an opening brace, we keep the line up to the brace.
    # If it's a pure import, keep it.
    lines
    |> Enum.reduce({[], 0}, fn line, {acc, brace_depth} ->
      trimmed = String.trim(line)
      
      # Track braces
      open_braces = length(Regex.scan(~r/\{/, line))
      close_braces = length(Regex.scan(~r/\}/, line))
      
      new_depth = brace_depth + open_braces - close_braces

      keep? = 
        if brace_depth == 0 do
          # We are at the root or class level
          String.starts_with?(trimmed, "import ") or
            String.starts_with?(trimmed, "export ") or
            String.starts_with?(trimmed, "class ") or
            String.starts_with?(trimmed, "interface ") or
            String.starts_with?(trimmed, "type ") or
            String.starts_with?(trimmed, "func ") or
            String.starts_with?(trimmed, "struct ") or
            String.starts_with?(trimmed, "impl ") or
            Regex.match?(~r/^(public|private|protected|async|static)?\s*\w+\s*\(/, trimmed)
        else
          false
        end

      acc = 
        if keep? do
          clean_line = String.split(line, "{") |> List.first() |> String.trim_trailing()
          [clean_line | acc]
        else
          acc
        end

      {acc, max(0, new_depth)}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.join("\n")
  end

  defp extract_python(lines) do
    # Keep imports, class defs, and function defs.
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
