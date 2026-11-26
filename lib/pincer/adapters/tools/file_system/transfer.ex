defmodule Pincer.Adapters.Tools.FileSystem.Transfer do
  @moduledoc """
  Path lifecycle, relocation, trash isolation, and channel dispatch for `FileSystem`.

  Handles `mkdir`, `copy`, `move`, `delete_to_trash`, and `send_to_channel`
  operations within the confined workspace root.
  """

  alias Pincer.Adapters.Tools.Args
  alias Pincer.Adapters.Tools.FileSystem

  @doc "Creates a directory (and any missing parent directories) within the workspace."
  @spec mkdir(String.t(), map(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def mkdir(path, _args, workspace_root) do
    case File.stat(path) do
      {:ok, %{type: :directory}} ->
        {:ok, "Created directory '#{FileSystem.relative_to_workspace(path, workspace_root)}'."}

      {:ok, %{type: :regular}} ->
        {:error, "Cannot create directory: file already exists at that path."}

      _ ->
        case File.mkdir_p(path) do
          :ok ->
            {:ok,
             "Created directory '#{FileSystem.relative_to_workspace(path, workspace_root)}'."}

          {:error, reason} ->
            {:error, "Error creating directory: #{inspect(reason)}"}
        end
    end
  end

  @doc "Copies a file or directory to a confined destination inside the workspace."
  @spec copy(String.t(), map(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def copy(path, args, workspace_root) do
    destination = Args.get(args, "_destination_path")
    overwrite? = Args.get(args, "overwrite") == true

    with :ok <- ensure_destination_available(destination, overwrite?),
         :ok <- ensure_parent_directory(destination),
         :ok <- copy_path(path, destination, overwrite?) do
      {:ok,
       "Copied '#{FileSystem.relative_to_workspace(path, workspace_root)}' to '#{FileSystem.relative_to_workspace(destination, workspace_root)}'."}
    end
  end

  @doc "Moves a file or directory to a confined destination inside the workspace."
  @spec move(String.t(), map(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def move(path, args, workspace_root) do
    destination = Args.get(args, "_destination_path")
    overwrite? = Args.get(args, "overwrite") == true

    with :ok <- ensure_not_workspace_root(path, workspace_root),
         :ok <- ensure_not_descendant_move(path, destination),
         :ok <- ensure_destination_available(destination, overwrite?),
         :ok <- ensure_parent_directory(destination),
         :ok <- move_path(path, destination, overwrite?) do
      {:ok,
       "Moved '#{FileSystem.relative_to_workspace(path, workspace_root)}' to '#{FileSystem.relative_to_workspace(destination, workspace_root)}'."}
    end
  end

  @doc "Moves a file or directory into the workspace `.trash` directory."
  @spec delete_to_trash(String.t(), map(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def delete_to_trash(path, _args, workspace_root) do
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
                 "Moved '#{FileSystem.relative_to_workspace(path, workspace_root)}' to '#{FileSystem.relative_to_workspace(destination, workspace_root)}'."}

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

  @doc "Broadcasts a workspace file to the active session channel."
  @spec send_to_channel(String.t(), map(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def send_to_channel(path, args, workspace_root) do
    session_id = Args.get(args, "session_id") || Args.get(args, "_session_id")
    caption = Args.get(args, "caption")

    if is_nil(session_id) or session_id == "" do
      {:error, "send_to_channel requires a session context — run from within an active session."}
    else
      rel_path = FileSystem.relative_to_workspace(path, workspace_root)

      case File.stat(path) do
        {:error, _} ->
          {:error, "File not found: #{rel_path}"}

        {:ok, %{type: :directory}} ->
          {:error, "Cannot send a directory. Zip it first with the 'zip' action."}

        {:ok, _} ->
          opts = if is_binary(caption) and caption != "", do: %{caption: caption}, else: %{}
          Pincer.Infra.PubSub.broadcast("session:#{session_id}", {:agent_file, path, opts})
          {:ok, "Sending '#{rel_path}' to the channel..."}
      end
    end
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

  defp trash_destination(path, workspace_root, trash_root) do
    timestamp = System.system_time(:millisecond)

    basename =
      path
      |> Path.relative_to(workspace_root)
      |> String.replace("/", "__")

    Path.join(trash_root, "#{timestamp}_#{basename}")
  end
end
