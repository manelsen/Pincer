defmodule Pincer.Adapters.Tools.CodeSkeleton do
  @moduledoc """
  Tool to extract the structural skeleton of a source code file within the workspace.
  """
  @behaviour Pincer.Ports.Tool

  alias Pincer.Core.WorkspaceGuard
  alias Pincer.Utils.CodeSkeleton

  @impl true
  def spec do
    %{
      name: "get_code_skeleton",
      description:
        "Reads a source code file and returns its structural skeleton (functions, classes, imports) while stripping out implementation details. Use this to quickly map the architecture of large files without consuming too many context tokens.",
      parameters: %{
        type: "object",
        properties: %{
          file_path: %{
            type: "string",
            description: "The workspace-relative path to the source code file to analyze."
          }
        },
        required: ["file_path"]
      }
    }
  end

  @impl true
  def execute(args, context \\ %{})

  def execute(%{"file_path" => file_path} = args, context)
      when is_binary(file_path) and is_map(context) do
    workspace =
      Map.get(context, "workspace_path") ||
        Map.get(context, :workspace_path) ||
        Map.get(args, "workspace_path") ||
        File.cwd!()

    with {:ok, safe_path} <-
           WorkspaceGuard.confine_path(file_path, root: workspace, reject_parent_segments: true),
         {:ok, content} <- File.read(safe_path) do
      ext = Path.extname(safe_path)
      skeleton = CodeSkeleton.extract(content, ext)
      {:ok, skeleton}
    else
      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, "Could not read file: #{inspect(reason)}"}
    end
  end

  def execute(_args, _context) do
    {:error, "Missing required parameter: file_path"}
  end
end
