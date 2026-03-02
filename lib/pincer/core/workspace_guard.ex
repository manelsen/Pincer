defmodule Pincer.Core.WorkspaceGuard do
  @moduledoc """
  Shared path-confinement guard for workspace-scoped runtime operations.

  The guard enforces:
  - null-byte rejection
  - optional explicit `..` traversal rejection
  - workspace confinement by expanded path prefix
  - symlink-escape blocking via nearest existing ancestor resolution
  """

  @outside_workspace_error "Access denied: Path outside workspace"

  @spec confine_path(String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def confine_path(path, opts \\ [])

  def confine_path(path, _opts) when not is_binary(path), do: {:error, "Invalid path"}

  def confine_path(path, opts) do
    reject_parent_segments = Keyword.get(opts, :reject_parent_segments, true)
    root = opts |> Keyword.get(:root, File.cwd!()) |> Path.expand() |> canonical_root()

    cond do
      String.contains?(path, "\0") ->
        {:error, "Path contains null bytes"}

      reject_parent_segments and String.contains?(path, "..") ->
        {:error, "Path traversal (..) not allowed"}

      true ->
        full_path = Path.expand(path, root)

        with :ok <- ensure_within_workspace(full_path, root),
             :ok <- ensure_existing_ancestor_within_workspace(full_path, root) do
          {:ok, full_path}
        end
    end
  end

  @spec outside_workspace_error() :: String.t()
  def outside_workspace_error, do: @outside_workspace_error

  defp canonical_root(root) do
    case resolve_existing_path(root) do
      {:ok, real_root} -> real_root
      {:error, _reason} -> root
    end
  end

  defp ensure_existing_ancestor_within_workspace(full_path, root) do
    with {:ok, ancestor} <- existing_ancestor(full_path),
         {:ok, real_ancestor} <- resolve_existing_path(ancestor),
         :ok <- ensure_within_workspace(real_ancestor, root) do
      :ok
    else
      {:error, @outside_workspace_error} = error -> error
      {:error, _reason} -> :ok
    end
  end

  defp existing_ancestor(path) do
    cond do
      existing_path_or_symlink?(path) ->
        {:ok, path}

      true ->
        parent = Path.dirname(path)

        if parent == path do
          {:error, :no_existing_ancestor}
        else
          existing_ancestor(parent)
        end
    end
  end

  defp existing_path_or_symlink?(path) do
    File.exists?(path) or match?({:ok, %{type: :symlink}}, File.lstat(path))
  end

  defp resolve_existing_path(path) do
    path
    |> Path.expand()
    |> Path.split()
    |> Enum.reduce_while("", fn segment, current ->
      next_path = append_path_segment(current, segment)

      case File.lstat(next_path) do
        {:ok, %{type: :symlink}} ->
          case File.read_link(next_path) do
            {:ok, target} ->
              resolved_target =
                if Path.type(target) == :absolute do
                  Path.expand(target)
                else
                  Path.expand(target, Path.dirname(next_path))
                end

              {:cont, resolved_target}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end

        {:ok, _other} ->
          {:cont, next_path}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:error, _reason} = error -> error
      resolved when is_binary(resolved) -> {:ok, resolved}
    end
  end

  defp append_path_segment("", "/"), do: "/"
  defp append_path_segment("", segment), do: segment
  defp append_path_segment("/", segment), do: Path.join("/", segment)
  defp append_path_segment(current, segment), do: Path.join(current, segment)

  defp ensure_within_workspace(path, root) do
    if path == root or String.starts_with?(path, root <> "/") do
      :ok
    else
      {:error, @outside_workspace_error}
    end
  end
end
