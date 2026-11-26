defmodule Pincer.Adapters.Tools.FileSystem.Walk do
  @moduledoc """
  Directory traversal, discovery, search, and metadata inspection for `FileSystem`.

  Handles `list`, `find`, `search`, and `stat` operations within a confined
  workspace root, skipping build/VCS directories and symlinks during recursive walks.
  """

  alias Pincer.Adapters.Tools.Args
  alias Pincer.Adapters.Tools.FileSystem

  @max_file_size Application.compile_env(:pincer, :fs_max_file_size, 52_428_800)
  @max_search_results Application.compile_env(:pincer, :fs_max_search_results, 100)
  @search_skip_dirs [".git", "_build", "deps", "node_modules"]
  @snippet_limit Application.compile_env(:pincer, :fs_snippet_limit, 160)

  @doc "Lists entries in a confined directory, optionally recursively."
  @spec list(String.t(), map(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def list(path, args, workspace_root) do
    rel = FileSystem.relative_to_workspace(path, workspace_root)

    if Args.get(args, "recursive") == true do
      case list_recursive(path, workspace_root) do
        {:ok, entries} ->
          {:ok,
           Jason.encode!(%{
             action: "list",
             path: rel,
             recursive: true,
             total: length(entries),
             entries: entries
           })}

        {:error, reason} ->
          {:error, reason}
      end
    else
      case File.ls(path) do
        {:ok, files} ->
          sorted = Enum.sort(files)

          {:ok,
           Jason.encode!(%{
             action: "list",
             path: rel,
             recursive: false,
             total: length(sorted),
             entries: sorted
           })}

        {:error, reason} ->
          {:error, "Error listing: #{inspect(reason)}"}
      end
    end
  end

  @doc "Finds files or directories matching optional type, extension, and glob filters."
  @spec find(String.t(), map(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def find(path, args, workspace_root) do
    limit = normalize_max_results(Args.get(args, "max_results"))

    with {:ok, find_opts} <- normalize_find_opts(args),
         {:ok, entries} <- find_paths(path, workspace_root, limit, find_opts) do
      {:ok,
       Jason.encode!(%{
         action: "find",
         path: FileSystem.relative_to_workspace(path, workspace_root),
         total: length(entries),
         truncated: length(entries) >= limit,
         limit: limit,
         entries: entries
       })}
    end
  end

  @doc "Searches UTF-8 text files recursively for a query string."
  @spec search(String.t(), map(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def search(path, args, workspace_root) do
    limit = normalize_max_results(Args.get(args, "max_results"))

    with {:ok, query} <- FileSystem.fetch_required_string(args, "query"),
         {:ok, search_opts} <- normalize_search_opts(args),
         {:ok, matches} <- search_path(path, workspace_root, query, limit, search_opts) do
      {:ok,
       Jason.encode!(%{
         action: "search",
         query: query,
         total: length(matches),
         truncated: length(matches) >= limit,
         limit: limit,
         matches: matches
       })}
    end
  end

  @doc "Returns lstat metadata (type, size, mtime) for a confined path."
  @spec stat(String.t(), map(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def stat(path, _args, workspace_root) do
    case File.lstat(path) do
      {:ok, stat} ->
        {:ok,
         Jason.encode!(%{
           action: "stat",
           path: FileSystem.relative_to_workspace(path, workspace_root),
           type: stat.type,
           size: stat.size,
           mtime: format_mtime(stat.mtime)
         })}

      {:error, reason} ->
        {:error, "File not found or inaccessible: #{inspect(reason)}"}
    end
  end

  defp normalize_max_results(value) when is_integer(value),
    do: value |> min(@max_search_results) |> max(1)

  defp normalize_max_results(_value), do: 200

  defp normalize_search_opts(args) do
    extension =
      case Args.get(args, "extension") do
        nil -> nil
        value when is_binary(value) -> normalize_extension(value)
        _ -> :invalid
      end

    if extension == :invalid do
      {:error, "Missing or invalid 'extension'."}
    else
      case_sensitive? = Args.get(args, "case_sensitive") == true

      {:ok,
       %{
         query: normalize_query(Args.get(args, "query"), case_sensitive?),
         case_sensitive?: case_sensitive?,
         extension: extension
       }}
    end
  end

  defp normalize_find_opts(args) do
    type =
      case Args.get(args, "type") || "any" do
        value when value in ["file", "directory", "any"] -> value
        _ -> :invalid
      end

    extension =
      case Args.get(args, "extension") do
        nil -> nil
        value when is_binary(value) -> normalize_extension(value)
        _ -> :invalid
      end

    glob =
      case Args.get(args, "glob") do
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

  defp list_recursive(path, workspace_root) do
    case do_list_recursive(path, workspace_root, []) do
      {:ok, entries_rev} -> {:ok, Enum.reverse(entries_rev)}
      {:error, reason} -> {:error, reason}
    end
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
            [FileSystem.relative_to_workspace(path, workspace_root) | acc]
          end

        walk_directory_children(path, workspace_root, {:ok, base_acc}, fn safe_child, inner_acc ->
          do_list_recursive(safe_child, workspace_root, inner_acc)
        end)

      {:ok, %{type: :regular}} ->
        {:ok, [FileSystem.relative_to_workspace(path, workspace_root) | acc]}

      {:ok, _other} ->
        {:ok, acc}

      {:error, reason} ->
        {:error, "File not found or inaccessible: #{inspect(reason)}"}
    end
  end

  defp find_paths(path, workspace_root, limit, opts) do
    case do_find_paths(path, workspace_root, limit, {[], 0}, opts) do
      {:ok, {entries_rev, _count}} ->
        {:ok, entries_rev |> Enum.reverse() |> Enum.take(limit)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_find_paths(_path, _workspace_root, limit, {_acc, count} = state, _opts)
       when count >= limit do
    {:ok, state}
  end

  defp do_find_paths(path, workspace_root, limit, state, opts) do
    case File.lstat(path) do
      {:ok, %{type: :symlink}} ->
        {:ok, state}

      {:ok, %{type: :directory}} ->
        {_acc, count} =
          next_state =
          maybe_collect_find_entry(
            path,
            workspace_root,
            :directory,
            state,
            opts,
            path != workspace_root
          )

        if count >= limit do
          {:ok, next_state}
        else
          walk_directory_children(path, workspace_root, {:ok, next_state}, fn safe_child,
                                                                              inner_state ->
            case do_find_paths(safe_child, workspace_root, limit, inner_state, opts) do
              {:ok, {_entries, child_count} = updated} when child_count >= limit ->
                {:halt, {:ok, updated}}

              {:ok, updated} ->
                {:cont, {:ok, updated}}

              {:error, _reason} ->
                {:cont, {:ok, inner_state}}
            end
          end)
        end

      {:ok, %{type: :regular}} ->
        {:ok, maybe_collect_find_entry(path, workspace_root, :regular, state, opts, true)}

      {:ok, _other} ->
        {:ok, state}

      {:error, reason} ->
        {:error, "File not found or inaccessible: #{inspect(reason)}"}
    end
  end

  defp maybe_collect_find_entry(path, workspace_root, type, {acc, count} = state, opts, include?) do
    cond do
      not include? -> state
      not find_type_matches?(type, opts.type) -> state
      not find_glob_matches?(path, opts.glob) -> state
      not find_extension_matches?(path, type, opts.extension) -> state
      true -> {[FileSystem.relative_to_workspace(path, workspace_root) | acc], count + 1}
    end
  end

  defp search_path(path, workspace_root, query, limit, opts) do
    normalized_query = normalize_query(query, opts.case_sensitive?)

    case do_search_path(path, workspace_root, normalized_query, limit, {[], 0}, opts) do
      {:ok, {matches_rev, _count}} ->
        {:ok, matches_rev |> Enum.reverse() |> Enum.take(limit)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_search_path(_path, _workspace_root, _query, limit, {_matches, count} = state, _opts)
       when count >= limit do
    {:ok, state}
  end

  defp do_search_path(path, workspace_root, query, limit, state, opts) do
    case File.lstat(path) do
      {:ok, %{type: :symlink}} ->
        {:ok, state}

      {:ok, %{type: :directory}} ->
        walk_directory_children(path, workspace_root, {:ok, state}, fn safe_child, inner_state ->
          case do_search_path(safe_child, workspace_root, query, limit, inner_state, opts) do
            {:ok, {_matches, child_count} = updated} when child_count >= limit ->
              {:halt, {:ok, updated}}

            {:ok, updated} ->
              {:cont, {:ok, updated}}

            {:error, _reason} ->
              {:cont, {:ok, inner_state}}
          end
        end)

      {:ok, %{type: :regular}} ->
        case search_file(path, workspace_root, query, limit, state, opts) do
          {:ok, next_state} -> {:ok, next_state}
          {:skip, _reason} -> {:ok, state}
          {:error, reason} -> {:error, reason}
        end

      {:ok, _other} ->
        {:ok, state}

      {:error, reason} ->
        {:error, "File not found or inaccessible: #{inspect(reason)}"}
    end
  end

  defp search_file(_path, _workspace_root, _query, limit, {_matches, count} = state, _opts)
       when count >= limit do
    {:ok, state}
  end

  defp search_file(path, workspace_root, query, limit, state, opts) do
    case File.stat(path) do
      {:ok, %{size: size}} when size > @max_file_size ->
        {:skip, :too_large}

      {:ok, %{type: :regular}} ->
        if search_extension_matches?(path, opts.extension) do
          read_and_search_file(path, workspace_root, query, limit, state, opts)
        else
          {:skip, :extension_mismatch}
        end

      {:ok, _other} ->
        {:skip, :not_regular}

      {:error, reason} ->
        {:error, "File not found or inaccessible: #{inspect(reason)}"}
    end
  end

  defp read_and_search_file(path, workspace_root, query, limit, state, opts) do
    case File.read(path) do
      {:ok, content} ->
        if String.valid?(content) and not String.contains?(content, "\0") do
          rel_path = FileSystem.relative_to_workspace(path, workspace_root)

          next_state =
            content
            |> String.split("\n")
            |> Enum.with_index(1)
            |> Enum.reduce_while(state, fn {line, line_number}, {acc, count} ->
              if search_match?(line, query, opts.case_sensitive?) do
                hit = %{
                  path: rel_path,
                  line: line_number,
                  snippet: truncate_snippet(line)
                }

                next_count = count + 1
                next_acc = [hit | acc]

                if next_count >= limit,
                  do: {:halt, {next_acc, next_count}},
                  else: {:cont, {next_acc, next_count}}
              else
                {:cont, {acc, count}}
              end
            end)

          {:ok, next_state}
        else
          {:skip, :binary}
        end

      {:error, reason} ->
        {:error, "Error reading file: #{inspect(reason)}"}
    end
  end

  defp walk_directory_children(path, workspace_root, initial_acc, step_fn) do
    case File.ls(path) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.reject(&(&1 in @search_skip_dirs))
        |> Enum.reduce_while(initial_acc, fn entry, {:ok, acc} ->
          child = Path.join(path, entry)

          case FileSystem.validate_path(child, workspace_root) do
            {:ok, safe_child} ->
              case step_fn.(safe_child, acc) do
                {:halt, result} -> {:halt, result}
                {:cont, result} -> {:cont, result}
                {:ok, next_acc} -> {:cont, {:ok, next_acc}}
                {:error, reason} -> {:halt, {:error, reason}}
              end

            {:error, _reason} ->
              {:cont, {:ok, acc}}
          end
        end)

      {:error, reason} ->
        {:error, "Error listing directory: #{inspect(reason)}"}
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

  defp truncate_snippet(line) do
    trimmed = String.trim(line)

    if String.length(trimmed) <= @snippet_limit do
      trimmed
    else
      String.slice(trimmed, 0, @snippet_limit) <> "..."
    end
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
end
