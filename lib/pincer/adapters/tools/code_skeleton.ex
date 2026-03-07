defmodule Pincer.Adapters.Tools.CodeSkeleton do
  @moduledoc """
  Tool to extract the structural skeleton of a source code file.
  """
  @behaviour Pincer.Ports.Tool

  alias Pincer.Utils.CodeSkeleton

  @impl true
  def spec do
    %{
      "type" => "function",
      "function" => %{
        "name" => "get_code_skeleton",
        "description" => "Reads a source code file and returns its structural skeleton (functions, classes, imports) while stripping out implementation details. Use this to quickly map the architecture of large files without consuming too many context tokens.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "file_path" => %{
              "type" => "string",
              "description" => "The path to the source code file to analyze."
            }
          },
          "required" => ["file_path"]
        }
      }
    }
  end

  @impl true
  def execute(%{"file_path" => file_path}) do
    case File.read(file_path) do
      {:ok, content} ->
        ext = Path.extname(file_path)
        skeleton = CodeSkeleton.extract(content, ext)
        {:ok, skeleton}

      {:error, reason} ->
        {:error, "Could not read file: #{inspect(reason)}"}
    end
  end
end
