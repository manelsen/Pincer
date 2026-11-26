defmodule Pincer.Adapters.Tools.FileSystem.Archive do
  @moduledoc """
  ZIP archive creation and extraction with Zip Slip confinement for `FileSystem`.

  Handles `zip` and `unzip` operations while validating every archive entry
  against absolute paths, traversal segments, symlinks, null bytes, and
  workspace boundary escapes before extraction.
  """

  alias Pincer.Adapters.Tools.Args
  alias Pincer.Adapters.Tools.FileSystem
  alias Pincer.Core.WorkspaceGuard

  @doc "Compresses a file or directory within the workspace into a `.zip` archive."
  @spec zip(String.t(), map(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def zip(path, args, workspace_root) do
    destination = resolve_zip_destination(path, Args.get(args, "_destination_path"))

    case File.stat(path) do
      {:error, _} ->
        {:error, "Path not found: #{FileSystem.relative_to_workspace(path, workspace_root)}"}

      {:ok, _} ->
        files_to_zip = collect_zip_entries(path, workspace_root)

        relative_files =
          Enum.map(files_to_zip, fn abs_path ->
            abs_path |> Path.relative_to(workspace_root) |> String.to_charlist()
          end)

        zip_result =
          :zip.create(
            String.to_charlist(destination),
            relative_files,
            cwd: String.to_charlist(workspace_root)
          )

        case zip_result do
          {:ok, _} ->
            {:ok,
             "Created archive '#{FileSystem.relative_to_workspace(destination, workspace_root)}' with #{length(files_to_zip)} file(s)."}

          {:error, reason} ->
            {:error, "Failed to create zip: #{inspect(reason)}"}
        end
    end
  end

  @doc "Extracts a `.zip` archive after validating all entries against Zip Slip attacks."
  @spec unzip(String.t(), map(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def unzip(path, args, workspace_root) do
    dest_dir =
      case Args.get(args, "_destination_path") do
        d when is_binary(d) -> d
        _ -> Path.dirname(path)
      end

    with :ok <- validate_zip_entries(path, dest_dir, workspace_root),
         :ok <- File.mkdir_p(dest_dir),
         {:ok, files} <-
           :zip.extract(
             String.to_charlist(path),
             [{:cwd, String.to_charlist(dest_dir)}]
           ) do
      rel_dest = FileSystem.relative_to_workspace(dest_dir, workspace_root)
      {:ok, "Extracted #{length(files)} file(s) to '#{rel_dest}'."}
    else
      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, "Failed to extract zip: #{inspect(reason)}"}
    end
  end

  defp resolve_zip_destination(path, dest) do
    base =
      if is_binary(dest) and dest != "" do
        dest
      else
        path <> ".zip"
      end

    if String.ends_with?(base, ".zip"), do: base, else: base <> ".zip"
  end

  defp collect_zip_entries(path, workspace_root) do
    path
    |> do_collect_zip_entries(workspace_root, [])
    |> Enum.reverse()
  end

  defp do_collect_zip_entries(path, workspace_root, acc) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        path
        |> File.ls!()
        |> Enum.sort()
        |> Enum.reduce(acc, fn entry, inner_acc ->
          child = Path.join(path, entry)

          case FileSystem.validate_path(child, workspace_root) do
            {:ok, safe_child} -> do_collect_zip_entries(safe_child, workspace_root, inner_acc)
            {:error, _reason} -> inner_acc
          end
        end)

      {:ok, %{type: :regular}} ->
        [path | acc]

      _ ->
        acc
    end
  end

  defp validate_zip_entries(archive_path, dest_dir, workspace_root) do
    case :zip.table(String.to_charlist(archive_path)) do
      {:ok, entries} ->
        Enum.reduce_while(entries, :ok, fn
          {:zip_comment, _}, :ok ->
            {:cont, :ok}

          {:zip_file, name_charlist, file_info, _comment, _offset, _comp_size}, :ok ->
            entry = List.to_string(name_charlist)

            case validate_single_zip_entry(entry, file_info, dest_dir, workspace_root) do
              :ok -> {:cont, :ok}
              {:error, reason} -> {:halt, {:error, reason}}
            end

          _, :ok ->
            {:cont, :ok}
        end)

      {:error, reason} ->
        {:error, "Failed to inspect zip: #{inspect(reason)}"}
    end
  end

  defp validate_single_zip_entry(entry, file_info, dest_dir, workspace_root) do
    normalized = entry |> String.replace("\\", "/") |> String.trim_trailing("/")

    cond do
      entry == "" or String.contains?(entry, "\0") ->
        {:error, "Zip Slip blocked: unsafe archive entry '#{entry}'"}

      String.starts_with?(entry, "/") or String.starts_with?(entry, "\\") or
          Regex.match?(~r/^[A-Za-z]:/, entry) ->
        {:error, "Zip Slip blocked: unsafe archive entry '#{entry}'"}

      zip_symlink?(file_info) ->
        {:error, "Zip Slip blocked: symlink entry '#{entry}' is not allowed"}

      normalized == "" ->
        {:error, "Zip Slip blocked: unsafe archive entry '#{entry}'"}

      ".." in String.split(normalized, "/", trim: true) ->
        {:error, "Zip Slip blocked: unsafe archive entry '#{entry}'"}

      true ->
        with {:ok, target} <-
               WorkspaceGuard.confine_path(normalized,
                 root: dest_dir,
                 reject_parent_segments: true
               ),
             {:ok, _} <-
               WorkspaceGuard.confine_path(target,
                 root: workspace_root,
                 reject_parent_segments: true
               ) do
          :ok
        else
          {:error, _reason} ->
            {:error, "Zip Slip blocked: unsafe archive entry '#{entry}'"}
        end
    end
  end

  defp zip_symlink?(file_info) when is_tuple(file_info) and tuple_size(file_info) >= 8 do
    file_type = elem(file_info, 2)
    mode = elem(file_info, 7)
    file_type == :symlink or (is_integer(mode) and Bitwise.band(mode, 0o170000) == 0o120000)
  end

  defp zip_symlink?(_), do: false
end
