defmodule Pincer.Adapters.Tools.FileSystem do
  @moduledoc """
  Tools for file system manipulation with path confinement (jail).

  This module acts as the `Pincer.Ports.Tool` coordinator and `WorkspaceGuard`
  path confinement gateway, delegating execution to focused submodules:

  - `Pincer.Adapters.Tools.FileSystem.Walk` (`list`, `find`, `search`, `stat`)
  - `Pincer.Adapters.Tools.FileSystem.Edit` (`read`, `write`, `append`, `patch`, `anchored_edit`)
  - `Pincer.Adapters.Tools.FileSystem.Archive` (`zip`, `unzip`)
  - `Pincer.Adapters.Tools.FileSystem.Transfer` (`mkdir`, `copy`, `move`, `delete_to_trash`, `send_to_channel`)

  ## Security Model

  1. **Workspace Confinement**: All paths must resolve to a location inside the workspace root.
  2. **Path Sanitization**:
     - `..` (parent directory) traversal is explicitly blocked.
     - Absolute paths are allowed ONLY if they point within the workspace.
     - Null bytes are rejected.
  3. **Constrained Mutations**: Write, patch, transfer, and archive operations use the
     same confinement guarantees as reads.
  """

  @behaviour Pincer.Ports.Tool

  alias Pincer.Adapters.Tools.Args
  alias Pincer.Adapters.Tools.FileSystem.Archive
  alias Pincer.Adapters.Tools.FileSystem.Edit
  alias Pincer.Adapters.Tools.FileSystem.Transfer
  alias Pincer.Adapters.Tools.FileSystem.Walk
  alias Pincer.Core.WorkspaceGuard

  require Logger

  @actions [
    %{name: "list", handler: {Walk, :list}, default_path: "."},
    %{name: "read", handler: {Edit, :read}},
    %{name: "write", handler: {Edit, :write}},
    %{name: "append", handler: {Edit, :append}},
    %{name: "mkdir", handler: {Transfer, :mkdir}},
    %{name: "copy", handler: {Transfer, :copy}, destination: :required},
    %{name: "move", handler: {Transfer, :move}, destination: :required},
    %{name: "search", handler: {Walk, :search}, default_path: "."},
    %{name: "find", handler: {Walk, :find}},
    %{name: "stat", handler: {Walk, :stat}},
    %{name: "anchored_edit", handler: {Edit, :anchored_edit}},
    %{name: "patch", handler: {Edit, :patch}},
    %{name: "delete_to_trash", handler: {Transfer, :delete_to_trash}},
    %{name: "zip", handler: {Archive, :zip}, destination: :required},
    %{name: "unzip", handler: {Archive, :unzip}, destination: :optional},
    %{name: "send_to_channel", handler: {Transfer, :send_to_channel}}
  ]

  @action_names Enum.map(@actions, & &1.name)
  @action_map Map.new(@actions, &{&1.name, &1})

  @doc "Returns the canonical list of supported `file_system` action names."
  @spec actions() :: [String.t()]
  def actions, do: @action_names

  @impl true
  def spec do
    %{
      name: "file_system",
      description:
        "Manages files and directories safely within the workspace. Always use workspace-relative paths such as '.', '.pincer', or 'lib/app.ex' instead of absolute container paths like '/app/workspaces/...'. Prefer read with hashline + anchored_edit for code edits. Use patch only for exact literal replacements.",
      parameters: %{
        type: "object",
        properties: %{
          action: %{
            type: "string",
            description: format_action_description(@action_names),
            enum: @action_names
          },
          path: %{
            type: "string",
            description:
              "File or directory path relative to workspace root. Examples: '.', '.pincer', 'lib/app.ex'. Do not use absolute container paths like '/app' or '/app/workspaces/...'."
          },
          content: %{
            type: "string",
            description: "Full file contents for the 'write' action."
          },
          destination: %{
            type: "string",
            description:
              "Target path for 'copy', 'move', and 'zip' actions. For 'unzip', optional extraction directory (defaults to same directory as the archive)."
          },
          caption: %{
            type: "string",
            description: "Optional caption text to accompany a file sent via 'send_to_channel'."
          },
          overwrite: %{
            type: "boolean",
            description: "Allow overwriting destination for 'copy' and 'move'."
          },
          query: %{
            type: "string",
            description: "Case-insensitive text query for the 'search' action."
          },
          max_results: %{
            type: "integer",
            description: "Maximum number of search matches to return (default: 20)."
          },
          from_line: %{
            type: "integer",
            description: "1-based line offset for ranged reads."
          },
          line_count: %{
            type: "integer",
            description: "Number of lines to return for ranged reads."
          },
          tail_lines: %{
            type: "integer",
            description: "Number of trailing lines to return for ranged reads."
          },
          recursive: %{
            type: "boolean",
            description: "Enable recursive listing for the 'list' action."
          },
          hashline: %{
            type: "boolean",
            description: "Return read output as line#hash|content. Use before anchored_edit."
          },
          extension: %{
            type: "string",
            description:
              "Optional file extension filter for 'search' (for example '.md' or 'md')."
          },
          glob: %{
            type: "string",
            description: "Optional basename glob for the 'find' action."
          },
          type: %{
            type: "string",
            description: "Optional type filter for the 'find' action.",
            enum: ["file", "directory", "any"]
          },
          edits: %{
            type: "array",
            description:
              "Anchored edits for the 'anchored_edit' action using replace, insert_after, or insert_before.",
            items: %{
              type: "object",
              properties: %{
                anchor: %{
                  type: "string",
                  description:
                    "Line reference token from hashline output, e.g. '49#WHHXK' (the part before the '|' separator). Do NOT add any prefix."
                },
                op: %{
                  type: "string",
                  enum: ["replace", "insert_after", "insert_before"]
                },
                content: %{type: "string", description: "New content for the operation."}
              },
              required: ["anchor", "op", "content"]
            }
          },
          case_sensitive: %{
            type: "boolean",
            description: "Enable case-sensitive matching for 'search'."
          },
          old_text: %{
            type: "string",
            description:
              "Text to replace for the 'patch' action. Use patch only for exact literal replacements."
          },
          new_text: %{
            type: "string",
            description:
              "Replacement text for the 'patch' action. Use patch only for exact literal replacements."
          },
          replace_all: %{
            type: "boolean",
            description:
              "Replace every occurrence in 'patch' mode instead of requiring uniqueness."
          }
        },
        required: ["action"]
      }
    }
  end

  @impl true
  def execute(args, context \\ %{}) do
    Logger.debug("[FILE-SYSTEM] Incoming args: #{inspect(args)}")

    action = infer_action(args)
    action_spec = Map.get(@action_map, action)
    raw_path = Args.get(args, "path") || default_path(action_spec)
    workspace_root = Args.workspace_root(context, &get_workspace_root/0)

    session_id = Args.session_id(context)
    args = if is_binary(session_id), do: Map.put(args, "_session_id", session_id), else: args

    with {:ok, spec} <- fetch_action_spec(action_spec),
         {:ok, safe_path} <- validate_action_path(spec, raw_path, workspace_root),
         {:ok, normalized_args} <- normalize_args_for_action(spec, args, workspace_root) do
      perform_action(spec, safe_path, normalized_args, workspace_root)
    else
      {:error, reason} ->
        Logger.warning("[FILE-SYSTEM] Security violation: #{reason} (Path: #{inspect(raw_path)})")
        {:error, reason}
    end
  end

  @doc "Confines `path` within `root`, rejecting `..` traversal segments and null bytes."
  @spec validate_path(term(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def validate_path(path, _root) when not is_binary(path), do: {:error, "Invalid path"}

  def validate_path(path, root) do
    WorkspaceGuard.confine_path(path,
      root: root,
      reject_parent_segments: true
    )
  end

  @doc "Returns `path` relative to `workspace_root`."
  @spec relative_to_workspace(String.t(), String.t()) :: String.t()
  def relative_to_workspace(path, workspace_root), do: Path.relative_to(path, workspace_root)

  @doc "Fetches a required non-empty string argument from `args`."
  @spec fetch_required_string(map(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def fetch_required_string(args, key), do: string_arg(args, key, :nonempty)

  @doc "Fetches a raw string argument from `args` (allowing empty string)."
  @spec fetch_string(map(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def fetch_string(args, key), do: string_arg(args, key, :raw)

  defp get_workspace_root, do: File.cwd!()

  defp infer_action(args) do
    cond do
      a = Args.get(args, "action") -> a
      Args.get(args, "content") -> "write"
      Args.get(args, "old_text") && Args.get(args, "new_text") -> "patch"
      Args.get(args, "query") -> "search"
      Args.get(args, "path") -> "read"
      true -> nil
    end
  end

  defp default_path(%{default_path: path}), do: path
  defp default_path(_spec), do: nil

  defp fetch_action_spec(nil), do: {:error, "Invalid action."}
  defp fetch_action_spec(spec), do: {:ok, spec}

  defp validate_action_path(_spec, nil, _root),
    do: {:error, "Path is required for file_system operations."}

  defp validate_action_path(_spec, path, root), do: validate_path(path, root)

  defp normalize_args_for_action(%{destination: :required}, args, workspace_root) do
    with {:ok, destination} <- fetch_required_string(args, "destination"),
         {:ok, safe_destination} <- validate_path(destination, workspace_root) do
      {:ok, Map.put(args, "_destination_path", safe_destination)}
    end
  end

  defp normalize_args_for_action(%{destination: :optional}, args, workspace_root) do
    case Args.get(args, "destination") do
      dest when is_binary(dest) and dest != "" ->
        with {:ok, safe_dest} <- validate_path(dest, workspace_root) do
          {:ok, Map.put(args, "_destination_path", safe_dest)}
        end

      _ ->
        {:ok, args}
    end
  end

  defp normalize_args_for_action(_spec, args, _workspace_root), do: {:ok, args}

  defp perform_action(%{handler: {module, fun}}, safe_path, normalized_args, workspace_root) do
    apply(module, fun, [safe_path, normalized_args, workspace_root])
  end

  defp string_arg(args, key, mode) do
    case Args.string(Args.get(args, key), mode) do
      {:ok, value} -> {:ok, value}
      {:error, :empty} -> {:error, "'#{key}' cannot be empty."}
      {:error, _} -> {:error, "Missing or invalid '#{key}'."}
    end
  end

  defp format_action_description([last]), do: "Action to execute: '#{last}'"

  defp format_action_description(names) do
    {init, [last]} = Enum.split(names, -1)
    "Action to execute: " <> Enum.map_join(init, ", ", &"'#{&1}'") <> ", or '#{last}'"
  end
end
