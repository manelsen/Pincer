defmodule Pincer.Core.AlignmentIntegrity do
  @moduledoc """
  Tamper detection for agent personality files.

  Computes SHA-256 hashes of protected alignment files (IDENTITY.md, SOUL.md)
  and stores them in `.alignment-integrity.json` inside the workspace's
  `.pincer/` directory. On subsequent boots, hashes are re-verified to detect
  unauthorized modifications.

  ## Protected files

  Only `IDENTITY.md` and `SOUL.md` are protected — these define the agent's
  core personality contract. `USER.md` and `STYLE.md` are user-populated and
  expected to change over time.
  """

  alias Pincer.Core.AgentPaths

  @protected_filenames ~w(IDENTITY.md SOUL.md)
  @integrity_filename ".alignment-integrity.json"

  @doc """
  Returns `{name, path}` pairs for protected files that exist on disk.
  """
  @spec protected_files(String.t()) :: [{String.t(), String.t()}]
  def protected_files(workspace_path) do
    pincer_dir = AgentPaths.pincer_dir(workspace_path)

    @protected_filenames
    |> Enum.map(fn name -> {name, Path.join(pincer_dir, name)} end)
    |> Enum.filter(fn {_name, path} -> File.exists?(path) end)
  end

  @doc """
  Computes SHA-256 hashes of all protected files and writes them to
  the integrity file. Call this after workspace creation or bootstrap
  completion.
  """
  @spec snapshot!(String.t()) :: :ok
  def snapshot!(workspace_path) do
    hashes =
      workspace_path
      |> protected_files()
      |> Map.new(fn {name, path} -> {name, hash_file(path)} end)

    integrity_path = integrity_path(workspace_path)
    File.write!(integrity_path, Jason.encode!(hashes, pretty: true))
    :ok
  end

  @doc """
  Verifies current file hashes against the stored snapshot.

  Returns:
  - `{:ok, []}` — all files match
  - `{:ok, violations}` — list of `%{file: name, status: :tampered | :missing}`
  - `{:error, :no_snapshot}` — no integrity file found
  """
  @spec verify(String.t()) :: {:ok, [map()]} | {:error, :no_snapshot}
  def verify(workspace_path) do
    integrity_path = integrity_path(workspace_path)

    if File.exists?(integrity_path) do
      {:ok, stored} = integrity_path |> File.read!() |> Jason.decode()
      pincer_dir = AgentPaths.pincer_dir(workspace_path)

      violations =
        stored
        |> Enum.reduce([], fn {name, expected_hash}, acc ->
          path = Path.join(pincer_dir, name)

          cond do
            not File.exists?(path) ->
              [%{file: name, status: :missing} | acc]

            hash_file(path) != expected_hash ->
              [%{file: name, status: :tampered} | acc]

            true ->
              acc
          end
        end)
        |> Enum.reverse()

      {:ok, violations}
    else
      {:error, :no_snapshot}
    end
  end

  @doc """
  Path to the integrity JSON file for a workspace.
  """
  @spec integrity_path(String.t()) :: String.t()
  def integrity_path(workspace_path) do
    Path.join(AgentPaths.pincer_dir(workspace_path), @integrity_filename)
  end

  defp hash_file(path) do
    path
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
