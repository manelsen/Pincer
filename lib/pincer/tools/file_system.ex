defmodule Pincer.Tools.FileSystem do
  @moduledoc """
  Tools for file system manipulation with path confinement (jail).

  This module provides safe access to the file system by strictly confining operations
  to the application's workspace root. It prevents path traversal attacks and restricts
  access to sensitive system files.

  ## Security Model

  1. **Workspace Confinement**: All paths must resolve to a location inside the workspace root.
  2. **Path Sanitization**:
     - `..` (parent directory) traversal is explicitly blocked.
     - Absolute paths are allowed ONLY if they point within the workspace.
     - Null bytes are rejected.
  3. **Read-Only**: Currently supports listing and reading.

  ## Allowed Actions

  - `list`: List files in a directory.
  - `read`: Read file content.

  ## Security Constraints

  - **Blocked**: `../../etc/passwd` (Traversal)
  - **Blocked**: `/etc/shadow` (Absolute path outside workspace)
  - **Allowed**: `lib/pincer.ex` (Relative path inside workspace)
  """
  @behaviour Pincer.Tool
  alias Pincer.Core.WorkspaceGuard
  require Logger

  # 50 MB file-read limit. The practical ceiling is the LLM context window
  # (~500 KB of useful text), but we allow up to 50 MB so the agent can
  # handle large logs, datasets, and dumps without hitting an artificial wall.
  @max_file_size 52_428_800
  # Determine workspace root at runtime
  defp get_workspace_root, do: File.cwd!()

  @impl true
  def spec do
    %{
      name: "file_system",
      description: "Manages files and directories safely within the workspace.",
      parameters: %{
        type: "object",
        properties: %{
          action: %{
            type: "string",
            description: "Action to execute: 'list' or 'read'",
            enum: ["list", "read"]
          },
          path: %{
            type: "string",
            description: "File or directory path (relative to workspace root)."
          }
        },
        required: ["action"]
      }
    }
  end

  @impl true
  def execute(args) do
    action = Map.get(args, "action")
    raw_path = Map.get(args, "path", ".")

    with {:ok, safe_path} <- validate_path(raw_path) do
      perform_action(action, safe_path)
    else
      {:error, reason} ->
        Logger.warning("[FILE-SYSTEM] Security violation: #{reason} (Path: #{raw_path})")
        {:error, reason}
    end
  end

  defp validate_path(path) when not is_binary(path), do: {:error, "Invalid path"}

  defp validate_path(path) do
    WorkspaceGuard.confine_path(path,
      root: get_workspace_root(),
      reject_parent_segments: true
    )
  end

  defp perform_action("list", path) do
    case File.ls(path) do
      {:ok, files} -> {:ok, "Files in '#{path}':\n" <> Enum.join(files, "\n")}
      {:error, reason} -> {:error, "Error listing: #{inspect(reason)}"}
    end
  end

  defp perform_action("read", path) do
    case File.stat(path) do
      {:ok, %{type: :regular, size: size}} when size > @max_file_size ->
        {:error, "File too large: #{size} bytes (limit: #{@max_file_size})"}

      {:ok, %{type: :regular}} ->
        case File.read(path) do
          {:ok, content} -> {:ok, content}
          {:error, reason} -> {:error, "Error reading: #{inspect(reason)}"}
        end

      {:ok, %{type: type}} ->
        {:error, "Cannot read non-file type: #{type}"}

      {:error, reason} ->
        {:error, "File not found or inaccessible: #{inspect(reason)}"}
    end
  end

  defp perform_action(_, _), do: {:error, "Invalid action."}
end
