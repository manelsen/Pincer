defmodule Pincer.Adapters.Tools.FileSystem do
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
  3. **Constrained Mutations**: Write and patch operations are allowed only inside
     the workspace root, using the same confinement guarantees as reads.

  ## Allowed Actions

  - `list`: List files in a directory.
  - `read`: Read file content.
  - `write`: Overwrite a file, creating parent directories when needed.
  - `append`: Append text to a file, creating parent directories when needed.
  - `mkdir`: Create directories recursively.
  - `copy`: Copy a file or directory within the workspace.
  - `move`: Move a file or directory within the workspace.
  - `search`: Recursively search text in files under the workspace.
  - `find`: Find files or directories recursively under the workspace.
  - `stat`: Inspect metadata for a file or directory.
  - `anchored_edit`: Edit files using verified line anchors.
  - `patch`: Replace exact text in a file.
  - `delete_to_trash`: Move a file or directory to the workspace trash.

  ## Security Constraints

  - **Blocked**: `../../etc/passwd` (Traversal)
  - **Blocked**: `/etc/shadow` (Absolute path outside workspace)
  - **Allowed**: `lib/pincer.ex` (Relative path inside workspace)
  """
  @behaviour Pincer.Ports.Tool
  alias Pincer.Core.WorkspaceGuard
  require Logger

  # 50 MB file-read limit. The practical ceiling is the LLM context window
  # (~500 KB of useful text), but we allow up to 50 MB so the agent can
  # handle large logs, datasets, and dumps without hitting an artificial wall.
  @max_file_size 52_428_800
  @max_search_results 100
  @search_skip_dirs [".git", "_build", "deps", "node_modules"]
  @snippet_limit 160
  @hashline_dict "ZPMQVRWSNKTXJBYH" |> String.graphemes() |> List.to_tuple()
  @line_ref_regex ~r/^(\d+)#([A-Z]{5})$/
  # Determine workspace root at runtime
  defp get_workspace_root, do: File.cwd!()

  @impl true
  def spec do
    %{
      name: "file_system",
      description:
        "Manages files and directories safely within the workspace. Prefer read with hashline + anchored_edit for code edits. Use patch only for exact literal replacements.",
      parameters: %{
        type: "object",
        properties: %{
          action: %{
            type: "string",
            description:
              "Action to execute: 'list', 'read', 'write', 'append', 'mkdir', 'copy', 'move', 'search', 'find', 'stat', 'anchored_edit', 'patch', or 'delete_to_trash'",
            enum: [
              "list",
              "read",
              "write",
              "append",
              "mkdir",
              "copy",
              "move",
              "search",
              "find",
              "stat",
              "anchored_edit",
              "patch",
              "delete_to_trash"
            ]
          },
          path: %{
            type: "string",
            description: "File or directory path (relative to workspace root)."
          },
          content: %{
            type: "string",
            description: "Full file contents for the 'write' action."
          },
          destination: %{
            type: "string",
            description: "Target path for the 'copy' and 'move' actions."
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
              "Anchored edits for the 'anchored_edit' action using replace, insert_after, or insert_before."
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
    # DEBUG: Log incoming arguments
    Logger.debug("[FILE-SYSTEM] Incoming args: #{inspect(args)}")

    action = infer_action(args)
    raw_path = get_arg(args, "path") || default_path(action)

    workspace_root =
      Map.get(context, "workspace_path") || Map.get(context, :workspace_path) ||
        get_workspace_root()

    with {:ok, safe_path} <- validate_action_path(action, raw_path, workspace_root),
         {:ok, normalized_args} <- normalize_args_for_action(action, args, workspace_root) do
      perform_action(action, safe_path, normalized_args, workspace_root)
    else
      {:error, reason} ->
        Logger.warning("[FILE-SYSTEM] Security violation: #{reason} (Path: #{inspect(raw_path)})")
        {:error, reason}
    end
  end

  defp infer_action(args) do
    cond do
      a = get_arg(args, "action") -> a
      get_arg(args, "content") -> "write"
      get_arg(args, "old_text") && get_arg(args, "new_text") -> "patch"
      get_arg(args, "query") -> "search"
      get_arg(args, "path") -> "read"
      true -> nil
    end
  end

  defp get_arg(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  end

  defp default_path("list"), do: "."
  defp default_path("search"), do: "."
  defp default_path(_action), do: nil

  defp validate_action_path(nil, _path, _root), do: {:error, "Invalid action."}

  defp validate_action_path(_action, nil, _root),
    do: {:error, "Path is required for file_system operations."}

  defp validate_action_path(action, path, root)
       when action in [
              "list",
              "read",
              "write",
              "append",
              "mkdir",
              "copy",
              "move",
              "search",
              "find",
              "stat",
              "anchored_edit",
              "patch",
              "delete_to_trash"
            ] do
    validate_path(path, root)
  end

  defp validate_action_path(_action, _path, _root), do: {:error, "Invalid action."}

  defp normalize_args_for_action(action, args, workspace_root) when action in ["copy", "move"] do
    with {:ok, destination} <- fetch_required_string(args, "destination"),
         {:ok, safe_destination} <- validate_path(destination, workspace_root) do
      {:ok, Map.put(args, "_destination_path", safe_destination)}
    end
  end

  defp normalize_args_for_action(_action, args, _workspace_root), do: {:ok, args}

  defp validate_path(path, _root) when not is_binary(path), do: {:error, "Invalid path"}

  defp validate_path(path, root) do
    WorkspaceGuard.confine_path(path,
      root: root,
      reject_parent_segments: true
    )
  end

  defp perform_action("list", path, args, workspace_root) do
    if get_arg(args, "recursive") == true do
      case list_recursive(path, workspace_root) do
        {:ok, entries} ->
          {:ok,
           "Files in '#{relative_to_workspace(path, workspace_root)}':\n" <>
             Enum.join(entries, "\n")}

        {:error, reason} ->
          {:error, reason}
      end
    else
      case File.ls(path) do
        {:ok, files} -> {:ok, "Files in '#{path}':\n" <> Enum.join(files, "\n")}
        {:error, reason} -> {:error, "Error listing: #{inspect(reason)}"}
      end
    end
  end

  defp perform_action("read", path, args, _workspace_root) do
    if invalid_read_range?(args) do
      {:error, "Cannot combine 'tail_lines' with 'from_line' or 'line_count'."}
    else
      do_read(path, args)
    end
  end

  defp perform_action("write", path, args, workspace_root) do
    content = get_arg(args, "content")

    if is_binary(content) do
      case File.stat(path) do
        {:ok, %{type: :directory}} ->
          {:error, "Cannot write to a directory."}

        _ ->
          path
          |> Path.dirname()
          |> File.mkdir_p()

          case File.write(path, content) do
            :ok ->
              {:ok,
               "Wrote #{byte_size(content)} bytes to '#{relative_to_workspace(path, workspace_root)}'."}

            {:error, reason} ->
              {:error, "Error writing file: #{inspect(reason)}"}
          end
      end
    else
      {:error, "Write action requires string 'content'."}
    end
  end

  defp perform_action("append", path, args, workspace_root) do
    content = get_arg(args, "content")

    if is_binary(content) do
      case File.stat(path) do
        {:ok, %{type: :directory}} ->
          {:error, "Cannot append to a directory."}

        _ ->
          path
          |> Path.dirname()
          |> File.mkdir_p()

          case File.write(path, content, [:append]) do
            :ok ->
              {:ok,
               "Appended #{byte_size(content)} bytes to '#{relative_to_workspace(path, workspace_root)}'."}

            {:error, reason} ->
              {:error, "Error appending file: #{inspect(reason)}"}
          end
      end
    else
      {:error, "Append action requires string 'content'."}
    end
  end

  defp perform_action("mkdir", path, _args, workspace_root) do
    case File.stat(path) do
      {:ok, %{type: :directory}} ->
        {:ok, "Created directory '#{relative_to_workspace(path, workspace_root)}'."}

      {:ok, %{type: :regular}} ->
        {:error, "Cannot create directory: file already exists at that path."}

      _ ->
        case File.mkdir_p(path) do
          :ok ->
            {:ok, "Created directory '#{relative_to_workspace(path, workspace_root)}'."}

          {:error, reason} ->
            {:error, "Error creating directory: #{inspect(reason)}"}
        end
    end
  end

  defp perform_action("copy", path, args, workspace_root) do
    destination = get_arg(args, "_destination_path")
    overwrite? = get_arg(args, "overwrite") == true

    with :ok <- ensure_destination_available(destination, overwrite?),
         :ok <- ensure_parent_directory(destination),
         :ok <- copy_path(path, destination, overwrite?) do
      {:ok,
       "Copied '#{relative_to_workspace(path, workspace_root)}' to '#{relative_to_workspace(destination, workspace_root)}'."}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp perform_action("move", path, args, workspace_root) do
    destination = get_arg(args, "_destination_path")
    overwrite? = get_arg(args, "overwrite") == true

    with :ok <- ensure_not_workspace_root(path, workspace_root),
         :ok <- ensure_not_descendant_move(path, destination),
         :ok <- ensure_destination_available(destination, overwrite?),
         :ok <- ensure_parent_directory(destination),
         :ok <- move_path(path, destination, overwrite?) do
      {:ok,
       "Moved '#{relative_to_workspace(path, workspace_root)}' to '#{relative_to_workspace(destination, workspace_root)}'."}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp perform_action("find", path, args, workspace_root) do
    with {:ok, find_opts} <- normalize_find_opts(args),
         {:ok, entries} <-
           find_paths(
             path,
             workspace_root,
             normalize_max_results(get_arg(args, "max_results")),
             find_opts
           ) do
      case entries do
        [] ->
          {:ok, "No paths found in '#{relative_to_workspace(path, workspace_root)}'."}

        _ ->
          {:ok,
           "Found #{length(entries)} paths in '#{relative_to_workspace(path, workspace_root)}':\n" <>
             Enum.join(entries, "\n")}
      end
    end
  end

  defp perform_action("anchored_edit", path, args, workspace_root) do
    with {:ok, edits} <- normalize_anchored_edits(args),
         {:ok, content} <- read_regular_file(path),
         {:ok, updated_content, edit_count} <- apply_anchored_edits(content, edits),
         :ok <- write_updated_content(path, updated_content) do
      {:ok,
       "Applied #{edit_count} anchored edit(s) to '#{relative_to_workspace(path, workspace_root)}'."}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp perform_action("search", path, args, workspace_root) do
    with {:ok, query} <- fetch_required_string(args, "query"),
         {:ok, search_opts} <- normalize_search_opts(args),
         {:ok, matches} <-
           search_path(
             path,
             workspace_root,
             query,
             normalize_max_results(get_arg(args, "max_results")),
             search_opts
           ) do
      case matches do
        [] ->
          {:ok, "No matches found for '#{query}'."}

        entries ->
          rendered =
            entries
            |> Enum.map_join("\n", fn %{path: rel_path, line: line, snippet: snippet} ->
              "- #{rel_path}:#{line} #{snippet}"
            end)

          {:ok, "Found #{length(entries)} matches for '#{query}':\n#{rendered}"}
      end
    end
  end

  defp perform_action("stat", path, _args, workspace_root) do
    case File.lstat(path) do
      {:ok, stat} ->
        {:ok,
         [
           "path: #{relative_to_workspace(path, workspace_root)}",
           "type: #{stat.type}",
           "size: #{stat.size}",
           "mtime: #{format_mtime(stat.mtime)}"
         ]
         |> Enum.join("\n")}

      {:error, reason} ->
        {:error, "File not found or inaccessible: #{inspect(reason)}"}
    end
  end

  defp perform_action("patch", path, args, workspace_root) do
    with {:ok, old_text} <- fetch_required_string(args, "old_text"),
         {:ok, new_text} <- fetch_string(args, "new_text"),
         {:ok, content} <- read_regular_file(path),
         {:ok, updated, replacements} <- patch_content(content, old_text, new_text, args) do
      case File.write(path, updated) do
        :ok ->
          {:ok,
           "Patched #{replacements} occurrence(s) in '#{relative_to_workspace(path, workspace_root)}'."}

        {:error, reason} ->
          {:error, "Error writing patched file: #{inspect(reason)}"}
      end
    end
  end

  defp perform_action("delete_to_trash", path, _args, workspace_root) do
    trash_root = Path.join(workspace_root, ".trash")

    cond do
      path == workspace_root ->
        {:error, "Cannot move the workspace root to trash."}

      path == trash_root or String.starts_with?(path, trash_root <> "/") ->
        {:error, "Cannot move items that are already inside the workspace trash."}

      true ->
        case File.stat(path) do
          {:ok, _stat} ->
            :ok = File.mkdir_p(trash_root)
            destination = trash_destination(path, workspace_root, trash_root)

            case File.rename(path, destination) do
              :ok ->
                {:ok,
                 "Moved '#{relative_to_workspace(path, workspace_root)}' to '#{relative_to_workspace(destination, workspace_root)}'."}

              {:error, reason} ->
                {:error, "Error moving item to trash: #{inspect(reason)}"}
            end

          {:error, :enoent} ->
            {:error, "File not found or inaccessible: :enoent"}

          {:error, reason} ->
            {:error, "File not found or inaccessible: #{inspect(reason)}"}
        end
    end
  end

  defp perform_action(_, _path, _args, _workspace_root), do: {:error, "Invalid action."}

  defp fetch_required_string(args, key) do
    case fetch_string(args, key) do
      {:ok, ""} -> {:error, "'#{key}' cannot be empty."}
      {:ok, value} -> {:ok, value}
      error -> error
    end
  end

  defp fetch_string(args, key) do
    case get_arg(args, key) do
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, "Missing or invalid '#{key}'."}
    end
  end

  defp do_read(path, args) do
    case File.stat(path) do
      {:ok, %{type: :regular, size: size}} when size > @max_file_size ->
        {:error, "File too large: #{size} bytes (limit: #{@max_file_size})"}

      {:ok, %{type: :regular}} ->
        case File.read(path) do
          {:ok, content} ->
            content
            |> slice_read_content(args)
            |> render_read_output(args, content)

          {:error, reason} ->
            {:error, "Error reading: #{inspect(reason)}"}
        end

      {:ok, %{type: type}} ->
        {:error, "Cannot read non-file type: #{type}"}

      {:error, reason} ->
        {:error, "File not found or inaccessible: #{inspect(reason)}"}
    end
  end

  defp normalize_max_results(value) when is_integer(value),
    do: value |> min(@max_search_results) |> max(1)

  defp normalize_max_results(_value), do: 20

  defp normalize_search_opts(args) do
    extension =
      case get_arg(args, "extension") do
        nil -> nil
        value when is_binary(value) -> normalize_extension(value)
        _ -> :invalid
      end

    if extension == :invalid do
      {:error, "Missing or invalid 'extension'."}
    else
      {:ok,
       %{
         query: normalize_query(get_arg(args, "query"), get_arg(args, "case_sensitive") == true),
         case_sensitive?: get_arg(args, "case_sensitive") == true,
         extension: extension
       }}
    end
  end

  defp normalize_find_opts(args) do
    type =
      case get_arg(args, "type") || "any" do
        value when value in ["file", "directory", "any"] -> value
        _ -> :invalid
      end

    extension =
      case get_arg(args, "extension") do
        nil -> nil
        value when is_binary(value) -> normalize_extension(value)
        _ -> :invalid
      end

    glob =
      case get_arg(args, "glob") do
        nil -> "*"
        value when is_binary(value) and value != "" -> value
        _ -> :invalid
      end

    cond do
      type == :invalid -> {:error, "Missing or invalid 'type'."}
      extension == :invalid -> {:error, "Missing or invalid 'extension'."}
      glob == :invalid -> {:error, "Missing or invalid 'glob'."}
      true -> {:ok, %{type: type, extension: extension, glob: glob}}
    end
  end

  defp normalize_anchored_edits(args) do
    edits = get_arg(args, "edits")

    if is_list(edits) and edits != [] do
      edits
      |> Enum.with_index(1)
      |> Enum.reduce_while({:ok, []}, fn {edit, index}, {:ok, acc} ->
        case normalize_anchored_edit(edit, index) do
          {:ok, normalized} -> {:cont, {:ok, acc ++ [normalized]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    else
      {:error, "'anchored_edit' requires a non-empty 'edits' list."}
    end
  end

  defp normalize_anchored_edit(edit, index) when is_map(edit) do
    with {:ok, op} <- normalize_anchored_op(get_arg(edit, "op"), index),
         {:ok, anchor} <- fetch_anchored_ref(edit, "anchor", index),
         {:ok, content} <- fetch_required_string(edit, "content") do
      end_anchor =
        case get_arg(edit, "end_anchor") do
          nil -> nil
          value when is_binary(value) -> value
          _ -> :invalid
        end

      case {op, end_anchor} do
        {"replace", :invalid} ->
          {:error, "Edit #{index} has invalid 'end_anchor'."}

        {"replace", _} ->
          {:ok, %{op: op, anchor: anchor, end_anchor: end_anchor, content: content}}

        {_other, nil} ->
          {:ok, %{op: op, anchor: anchor, content: content}}

        {_other, _value} ->
          {:error, "Only 'replace' supports 'end_anchor'."}
      end
    end
  end

  defp normalize_anchored_edit(_edit, _index),
    do: {:error, "Each anchored edit must be an object."}

  defp normalize_anchored_op(op, _index) when op in ["replace", "insert_after", "insert_before"],
    do: {:ok, op}

  defp normalize_anchored_op(_op, index),
    do:
      {:error,
       "Edit #{index} has invalid 'op'. Expected replace, insert_after, or insert_before."}

  defp fetch_anchored_ref(args, key, index) do
    case get_arg(args, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "Edit #{index} is missing '#{key}'."}
    end
  end

  defp search_path(path, workspace_root, query, limit, opts) do
    do_search_path(
      path,
      workspace_root,
      normalize_query(query, opts.case_sensitive?),
      limit,
      [],
      opts
    )
  end

  defp find_paths(path, workspace_root, limit, opts) do
    do_find_paths(path, workspace_root, limit, [], opts)
  end

  defp do_find_paths(_path, _workspace_root, limit, acc, _opts) when length(acc) >= limit do
    {:ok, Enum.take(acc, limit)}
  end

  defp do_find_paths(path, workspace_root, limit, acc, opts) do
    case File.lstat(path) do
      {:ok, %{type: :symlink}} ->
        {:ok, acc}

      {:ok, %{type: :directory}} ->
        current_acc =
          maybe_collect_find_entry(
            path,
            workspace_root,
            :directory,
            acc,
            opts,
            path != workspace_root
          )

        if length(current_acc) >= limit do
          {:ok, Enum.take(current_acc, limit)}
        else
          path
          |> File.ls()
          |> case do
            {:ok, entries} ->
              entries
              |> Enum.sort()
              |> Enum.reject(&(&1 in @search_skip_dirs))
              |> Enum.reduce_while({:ok, current_acc}, fn entry, {:ok, inner_acc} ->
                child = Path.join(path, entry)

                case validate_path(child, workspace_root) do
                  {:ok, safe_child} ->
                    case do_find_paths(safe_child, workspace_root, limit, inner_acc, opts) do
                      {:ok, next_acc} when length(next_acc) >= limit ->
                        {:halt, {:ok, next_acc}}

                      {:ok, next_acc} ->
                        {:cont, {:ok, next_acc}}

                      {:error, _reason} ->
                        {:cont, {:ok, inner_acc}}
                    end

                  {:error, _reason} ->
                    {:cont, {:ok, inner_acc}}
                end
              end)

            {:error, reason} ->
              {:error, "Error listing directory: #{inspect(reason)}"}
          end
        end

      {:ok, %{type: :regular}} ->
        {:ok, maybe_collect_find_entry(path, workspace_root, :regular, acc, opts, true)}

      {:ok, _other} ->
        {:ok, acc}

      {:error, reason} ->
        {:error, "File not found or inaccessible: #{inspect(reason)}"}
    end
  end

  defp maybe_collect_find_entry(path, workspace_root, type, acc, opts, include?) do
    cond do
      not include? -> acc
      not find_type_matches?(type, opts.type) -> acc
      not find_glob_matches?(path, opts.glob) -> acc
      not find_extension_matches?(path, type, opts.extension) -> acc
      true -> acc ++ [relative_to_workspace(path, workspace_root)]
    end
  end

  defp do_search_path(_path, _workspace_root, _query, limit, matches, _opts)
       when length(matches) >= limit do
    {:ok, Enum.take(matches, limit)}
  end

  defp do_search_path(path, workspace_root, query, limit, matches, opts) do
    case File.lstat(path) do
      {:ok, %{type: :symlink}} ->
        {:ok, matches}

      {:ok, %{type: :directory}} ->
        path
        |> File.ls()
        |> case do
          {:ok, entries} ->
            entries
            |> Enum.sort()
            |> Enum.reject(&(&1 in @search_skip_dirs))
            |> Enum.reduce_while({:ok, matches}, fn entry, {:ok, acc} ->
              child = Path.join(path, entry)

              case validate_path(child, workspace_root) do
                {:ok, safe_child} ->
                  case do_search_path(safe_child, workspace_root, query, limit, acc, opts) do
                    {:ok, child_matches} when length(child_matches) >= limit ->
                      {:halt, {:ok, child_matches}}

                    {:ok, child_matches} ->
                      {:cont, {:ok, child_matches}}

                    {:error, _reason} ->
                      {:cont, {:ok, acc}}
                  end

                {:error, _reason} ->
                  {:cont, {:ok, acc}}
              end
            end)

          {:error, reason} ->
            {:error, "Error listing directory: #{inspect(reason)}"}
        end

      {:ok, %{type: :regular}} ->
        case search_file(path, workspace_root, query, limit - length(matches), opts) do
          {:ok, file_matches} -> {:ok, matches ++ file_matches}
          {:skip, _reason} -> {:ok, matches}
          {:error, reason} -> {:error, reason}
        end

      {:ok, _other} ->
        {:ok, matches}

      {:error, reason} ->
        {:error, "File not found or inaccessible: #{inspect(reason)}"}
    end
  end

  defp search_file(_path, _workspace_root, _query, remaining, _opts) when remaining <= 0,
    do: {:ok, []}

  defp search_file(path, workspace_root, query, remaining, opts) do
    case File.stat(path) do
      {:ok, %{size: size}} when size > @max_file_size ->
        {:skip, :too_large}

      {:ok, %{type: :regular}} ->
        cond do
          not search_extension_matches?(path, opts.extension) ->
            {:skip, :extension_mismatch}

          true ->
            case File.read(path) do
              {:ok, content} ->
                if String.valid?(content) and not String.contains?(content, "\0") do
                  hits =
                    content
                    |> String.split("\n")
                    |> Enum.with_index(1)
                    |> Enum.reduce_while([], fn {line, line_number}, acc ->
                      if search_match?(line, query, opts.case_sensitive?) do
                        hit = %{
                          path: relative_to_workspace(path, workspace_root),
                          line: line_number,
                          snippet: truncate_snippet(line)
                        }

                        next = acc ++ [hit]

                        if length(next) >= remaining, do: {:halt, next}, else: {:cont, next}
                      else
                        {:cont, acc}
                      end
                    end)

                  {:ok, hits}
                else
                  {:skip, :binary}
                end

              {:error, reason} ->
                {:error, "Error reading file: #{inspect(reason)}"}
            end
        end

      {:ok, _other} ->
        {:skip, :not_regular}

      {:error, reason} ->
        {:error, "File not found or inaccessible: #{inspect(reason)}"}
    end
  end

  defp read_regular_file(path) do
    case File.stat(path) do
      {:ok, %{type: :regular, size: size}} when size > @max_file_size ->
        {:error, "File too large: #{size} bytes (limit: #{@max_file_size})"}

      {:ok, %{type: :regular}} ->
        case File.read(path) do
          {:ok, content} ->
            if String.valid?(content) do
              {:ok, content}
            else
              {:error, "Patch action only supports UTF-8 text files."}
            end

          {:error, reason} ->
            {:error, "Error reading file: #{inspect(reason)}"}
        end

      {:ok, %{type: type}} ->
        {:error, "Cannot patch non-file type: #{type}"}

      {:error, reason} ->
        {:error, "File not found or inaccessible: #{inspect(reason)}"}
    end
  end

  defp patch_content(_content, "", _new_text, _args), do: {:error, "'old_text' cannot be empty."}

  defp patch_content(content, old_text, new_text, args) do
    occurrences = :binary.matches(content, old_text) |> length()
    replace_all? = get_arg(args, "replace_all") == true

    cond do
      occurrences == 0 ->
        {:error, "Patch target not found."}

      occurrences > 1 and not replace_all? ->
        {:error, "Patch target has multiple occurrences. Use 'replace_all' to confirm."}

      true ->
        updated = String.replace(content, old_text, new_text, global: replace_all?)
        replacements = if replace_all?, do: occurrences, else: 1
        {:ok, updated, replacements}
    end
  end

  defp relative_to_workspace(path, workspace_root) do
    Path.relative_to(path, workspace_root)
  end

  defp render_read_output(content, args, original_content) do
    if get_arg(args, "hashline") == true do
      {:ok, format_hashlined_content(content, args, original_content)}
    else
      {:ok, content}
    end
  end

  defp slice_read_content(content, args) do
    from_line = normalize_from_line(get_arg(args, "from_line"))
    line_count = normalize_line_count(get_arg(args, "line_count"))
    tail_lines = normalize_line_count(get_arg(args, "tail_lines"))

    cond do
      not is_nil(tail_lines) ->
        content
        |> String.split("\n", trim: false)
        |> take_tail_slice(tail_lines)
        |> Enum.join("\n")
        |> restore_trailing_newline(content)

      from_line == 1 and is_nil(line_count) ->
        content

      true ->
        content
        |> String.split("\n", trim: false)
        |> take_line_slice(from_line, line_count)
        |> Enum.join("\n")
        |> restore_trailing_newline(content)
    end
  end

  defp format_hashlined_content(content, args, original_content) do
    {lines, trailing_newline?} = split_content_lines(content)
    start_line = hashline_start_line(args, original_content, lines)

    rendered =
      lines
      |> Enum.with_index(start_line)
      |> Enum.map_join("\n", fn {line, line_number} ->
        "#{line_number}##{compute_line_hash(line_number, line)}|#{line}"
      end)

    if rendered != "" and trailing_newline?, do: rendered <> "\n", else: rendered
  end

  defp invalid_read_range?(args) do
    get_arg(args, "tail_lines") != nil and
      (get_arg(args, "from_line") != nil or get_arg(args, "line_count") != nil)
  end

  defp normalize_from_line(value) when is_integer(value) and value > 0, do: value
  defp normalize_from_line(_value), do: 1

  defp normalize_line_count(value) when is_integer(value) and value > 0, do: value
  defp normalize_line_count(_value), do: nil

  defp take_line_slice(lines, from_line, nil), do: Enum.drop(lines, from_line - 1)

  defp take_line_slice(lines, from_line, line_count),
    do: lines |> Enum.drop(from_line - 1) |> Enum.take(line_count)

  defp take_tail_slice(lines, tail_lines) do
    lines
    |> drop_trailing_empty_line()
    |> Enum.take(-tail_lines)
  end

  defp drop_trailing_empty_line([]), do: []

  defp drop_trailing_empty_line(lines) do
    if List.last(lines) == "" do
      Enum.drop(lines, -1)
    else
      lines
    end
  end

  defp restore_trailing_newline(result, original) do
    if result != "" and String.ends_with?(original, "\n"), do: result <> "\n", else: result
  end

  defp split_content_lines(content) do
    trailing_newline? = String.ends_with?(content, "\n")

    lines =
      content
      |> String.split("\n", trim: false)
      |> drop_trailing_empty_line()

    {lines, trailing_newline?}
  end

  defp hashline_start_line(args, original_content, rendered_lines) do
    from_line = get_arg(args, "from_line")
    tail_lines = get_arg(args, "tail_lines")

    cond do
      is_integer(from_line) and from_line > 0 ->
        from_line

      is_integer(tail_lines) and tail_lines > 0 ->
        {all_lines, _} = split_content_lines(original_content)
        max(length(all_lines) - length(rendered_lines) + 1, 1)

      true ->
        1
    end
  end

  defp normalize_extension(""), do: nil
  defp normalize_extension("."), do: nil
  defp normalize_extension(extension), do: "." <> String.trim_leading(extension, ".")

  defp normalize_query(query, false) when is_binary(query), do: String.downcase(query)
  defp normalize_query(query, _case_sensitive), do: query

  defp search_extension_matches?(_path, nil), do: true
  defp search_extension_matches?(path, extension), do: Path.extname(path) == extension

  defp search_match?(line, query, false), do: String.contains?(String.downcase(line), query)
  defp search_match?(line, query, true), do: String.contains?(line, query)

  defp list_recursive(path, workspace_root) do
    do_list_recursive(path, workspace_root, [])
  end

  defp do_list_recursive(path, workspace_root, acc) do
    case File.lstat(path) do
      {:ok, %{type: :symlink}} ->
        {:ok, acc}

      {:ok, %{type: :directory}} ->
        base_acc =
          if path == workspace_root do
            acc
          else
            acc ++ [relative_to_workspace(path, workspace_root)]
          end

        path
        |> File.ls()
        |> case do
          {:ok, entries} ->
            entries
            |> Enum.sort()
            |> Enum.reject(&(&1 in @search_skip_dirs))
            |> Enum.reduce_while({:ok, base_acc}, fn entry, {:ok, inner_acc} ->
              child = Path.join(path, entry)

              case validate_path(child, workspace_root) do
                {:ok, safe_child} ->
                  case do_list_recursive(safe_child, workspace_root, inner_acc) do
                    {:ok, next_acc} -> {:cont, {:ok, next_acc}}
                    {:error, reason} -> {:halt, {:error, reason}}
                  end

                {:error, _reason} ->
                  {:cont, {:ok, inner_acc}}
              end
            end)

          {:error, reason} ->
            {:error, "Error listing directory: #{inspect(reason)}"}
        end

      {:ok, %{type: :regular}} ->
        {:ok, acc ++ [relative_to_workspace(path, workspace_root)]}

      {:ok, _other} ->
        {:ok, acc}

      {:error, reason} ->
        {:error, "File not found or inaccessible: #{inspect(reason)}"}
    end
  end

  defp find_type_matches?(:regular, "file"), do: true
  defp find_type_matches?(:directory, "directory"), do: true
  defp find_type_matches?(:regular, "any"), do: true
  defp find_type_matches?(:directory, "any"), do: true
  defp find_type_matches?(_type, _filter), do: false

  defp find_glob_matches?(path, glob) do
    path
    |> Path.basename()
    |> String.match?(glob_to_regex(glob))
  end

  defp find_extension_matches?(_path, :directory, nil), do: true
  defp find_extension_matches?(_path, :directory, _extension), do: false
  defp find_extension_matches?(_path, :regular, nil), do: true
  defp find_extension_matches?(path, :regular, extension), do: Path.extname(path) == extension

  defp glob_to_regex(glob) do
    glob
    |> Regex.escape()
    |> String.replace("\\*", ".*")
    |> String.replace("\\?", ".")
    |> then(&Regex.compile!("^" <> &1 <> "$"))
  end

  defp apply_anchored_edits(content, edits) do
    {lines, trailing_newline?} = split_content_lines(content)

    with {:ok, validated_edits} <- validate_anchored_edits(lines, edits) do
      updated_lines =
        validated_edits
        |> Enum.sort_by(&anchored_sort_key/1, :desc)
        |> Enum.reduce(lines, &apply_anchored_edit/2)

      {:ok, join_content_lines(updated_lines, trailing_newline?), length(validated_edits)}
    end
  end

  defp validate_anchored_edits(lines, edits) do
    edits
    |> Enum.reduce_while({:ok, []}, fn edit, {:ok, acc} ->
      with {:ok, anchor} <- parse_line_ref(edit.anchor),
           :ok <- validate_line_anchor(lines, anchor),
           {:ok, normalized_edit} <- normalize_validated_edit(edit, lines, anchor) do
        {:cont, {:ok, acc ++ [normalized_edit]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize_validated_edit(%{op: "replace", end_anchor: nil} = edit, _lines, anchor) do
    {:ok, Map.put(edit, :anchor_data, anchor)}
  end

  defp normalize_validated_edit(%{op: "replace", end_anchor: end_anchor} = edit, lines, anchor) do
    with {:ok, parsed_end_anchor} <- parse_line_ref(end_anchor),
         :ok <- validate_line_anchor(lines, parsed_end_anchor),
         :ok <- validate_anchor_order(anchor, parsed_end_anchor) do
      {:ok, edit |> Map.put(:anchor_data, anchor) |> Map.put(:end_anchor_data, parsed_end_anchor)}
    end
  end

  defp normalize_validated_edit(edit, _lines, anchor) do
    {:ok, Map.put(edit, :anchor_data, anchor)}
  end

  defp validate_anchor_order(%{line: start_line}, %{line: end_line}) when end_line >= start_line,
    do: :ok

  defp validate_anchor_order(_start_anchor, _end_anchor),
    do: {:error, "'end_anchor' must be on or after 'anchor'."}

  defp anchored_sort_key(%{op: "replace", anchor_data: %{line: line}}), do: {line, 2}
  defp anchored_sort_key(%{op: "insert_after", anchor_data: %{line: line}}), do: {line, 1}
  defp anchored_sort_key(%{op: "insert_before", anchor_data: %{line: line}}), do: {line, 0}

  defp apply_anchored_edit(%{op: "replace", anchor_data: %{line: line}} = edit, lines) do
    replacement = split_edit_lines(edit.content)
    end_line = Map.get(edit, :end_anchor_data, %{line: line}).line
    prefix = Enum.take(lines, line - 1)
    suffix = Enum.drop(lines, end_line)
    prefix ++ replacement ++ suffix
  end

  defp apply_anchored_edit(
         %{op: "insert_after", anchor_data: %{line: line}, content: content},
         lines
       ) do
    insertion = split_edit_lines(content)
    {prefix, suffix} = Enum.split(lines, line)
    prefix ++ insertion ++ suffix
  end

  defp apply_anchored_edit(
         %{op: "insert_before", anchor_data: %{line: line}, content: content},
         lines
       ) do
    insertion = split_edit_lines(content)
    {prefix, suffix} = Enum.split(lines, line - 1)
    prefix ++ insertion ++ suffix
  end

  defp split_edit_lines(content) do
    content
    |> String.split("\n", trim: false)
    |> drop_trailing_empty_line()
  end

  defp join_content_lines([], _trailing_newline?), do: ""

  defp join_content_lines(lines, trailing_newline?) do
    rendered = Enum.join(lines, "\n")
    if trailing_newline?, do: rendered <> "\n", else: rendered
  end

  defp write_updated_content(path, content) do
    case File.write(path, content) do
      :ok -> :ok
      {:error, reason} -> {:error, "Error writing file: #{inspect(reason)}"}
    end
  end

  defp parse_line_ref(ref) when is_binary(ref) do
    case Regex.run(@line_ref_regex, String.trim(ref)) do
      [_, line, hash] ->
        {:ok, %{line: String.to_integer(line), hash: hash}}

      _ ->
        {:error, "Invalid line reference format: #{inspect(ref)}. Expected format: {line}#ID."}
    end
  end

  defp validate_line_anchor(lines, %{line: line, hash: hash}) do
    cond do
      line < 1 or line > length(lines) ->
        {:error, "Line number #{line} out of bounds. File has #{length(lines)} lines."}

      compute_line_hash(line, Enum.at(lines, line - 1, "")) != hash ->
        {:error, format_anchor_mismatch(line, hash, lines)}

      true ->
        :ok
    end
  end

  defp format_anchor_mismatch(line, expected_hash, lines) do
    lower = max(line - 2, 1)
    upper = min(line + 2, length(lines))

    window =
      lower..upper
      |> Enum.map_join("\n", fn current_line ->
        content = Enum.at(lines, current_line - 1, "")
        anchor = "#{current_line}##{compute_line_hash(current_line, content)}|#{content}"
        if current_line == line, do: ">>> " <> anchor, else: "    " <> anchor
      end)

    "Line #{line} has changed since last read (expected #{line}##{expected_hash}). Use updated anchors below:\n\n" <>
      window
  end

  defp compute_line_hash(line_number, content) do
    stripped =
      content
      |> String.trim_trailing("\r")
      |> String.replace(~r/\s+/u, "")

    seed =
      if String.match?(stripped, ~r/[\p{L}\p{N}]/u) do
        stripped
      else
        "#{line_number}:#{stripped}"
      end

    hash_bin = :crypto.hash(:sha256, seed)
    <<n1::4, n2::4, n3::4, n4::4, n5::4, _::bitstring>> = hash_bin

    [n1, n2, n3, n4, n5]
    |> Enum.map(&elem(@hashline_dict, &1))
    |> Enum.join()
  end

  defp format_mtime({{year, month, day}, {hour, minute, second}}) do
    :io_lib.format("~4..0B-~2..0B-~2..0B ~2..0B:~2..0B:~2..0B", [
      year,
      month,
      day,
      hour,
      minute,
      second
    ])
    |> IO.iodata_to_binary()
  end

  defp ensure_destination_available(destination, true) do
    case File.lstat(destination) do
      {:ok, %{type: :directory}} ->
        case File.rm_rf(destination) do
          {_removed, []} -> :ok
          {_removed, errors} -> {:error, "Could not overwrite destination: #{inspect(errors)}"}
        end

      {:ok, _stat} ->
        case File.rm(destination) do
          :ok -> :ok
          {:error, reason} -> {:error, "Could not overwrite destination: #{inspect(reason)}"}
        end

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, "Could not inspect destination: #{inspect(reason)}"}
    end
  end

  defp ensure_destination_available(destination, false) do
    if File.exists?(destination) do
      {:error, "Destination already exists. Use 'overwrite' to replace it."}
    else
      :ok
    end
  end

  defp ensure_parent_directory(destination) do
    destination
    |> Path.dirname()
    |> File.mkdir_p()
  end

  defp ensure_not_workspace_root(path, workspace_root) do
    if path == workspace_root do
      {:error, "Cannot move the workspace root."}
    else
      :ok
    end
  end

  defp ensure_not_descendant_move(path, destination) do
    if path == destination or String.starts_with?(destination, path <> "/") do
      {:error, "Cannot move a directory into its own descendant."}
    else
      :ok
    end
  end

  defp copy_path(path, destination, overwrite?) do
    case File.stat(path) do
      {:ok, %{type: :directory}} ->
        case File.cp_r(path, destination) do
          {:ok, _files} -> :ok
          {:error, reason, _file} -> {:error, "Error copying directory: #{inspect(reason)}"}
        end

      {:ok, _stat} ->
        case File.cp(path, destination) do
          :ok -> :ok
          {:error, reason} -> {:error, "Error copying file: #{inspect(reason)}"}
        end

      {:error, reason} ->
        if overwrite? do
          {:error, "Error copying path: #{inspect(reason)}"}
        else
          {:error, "File not found or inaccessible: #{inspect(reason)}"}
        end
    end
  end

  defp move_path(path, destination, _overwrite?) do
    case File.rename(path, destination) do
      :ok ->
        :ok

      {:error, :exdev} ->
        with :ok <- copy_path(path, destination, true),
             {_removed, []} <- File.rm_rf(path) do
          :ok
        else
          {:error, reason} -> {:error, reason}
          {_removed, errors} -> {:error, "Error removing source after move: #{inspect(errors)}"}
        end

      {:error, reason} ->
        {:error, "Error moving path: #{inspect(reason)}"}
    end
  end

  defp truncate_snippet(line) do
    trimmed = String.trim(line)

    if String.length(trimmed) <= @snippet_limit do
      trimmed
    else
      String.slice(trimmed, 0, @snippet_limit) <> "..."
    end
  end

  defp trash_destination(path, workspace_root, trash_root) do
    timestamp = System.system_time(:millisecond)

    basename =
      path
      |> Path.relative_to(workspace_root)
      |> String.replace("/", "__")

    Path.join(trash_root, "#{timestamp}_#{basename}")
  end
end
