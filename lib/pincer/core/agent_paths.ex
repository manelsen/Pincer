defmodule Pincer.Core.AgentPaths do
  @moduledoc """
  Canonical path resolver for per-agent workspaces.

  Runtime cognitive state for Pincer lives under `workspaces/<agent_id>/.pincer/`.
  Root agents bootstrap from persona templates shipped in `priv/pincer/templates/`.
  Sub-agents inherit persona files from the parent workspace, but never bootstrap.

  ## Template Resolution Order

  When seeding a new workspace, files are resolved in this order:

  1. **Explicit template_root** — `workspaces/.template/.pincer/<file>` (operator override)
  2. **priv/pincer/templates/<file>** — bundled defaults shipped with the release
  3. **Inline fallback** — hardcoded defaults for MEMORY.md and HISTORY.md
  """

  @pincer_dir ".pincer"
  @sessions_dir "sessions"
  @identity_file "IDENTITY.md"
  @soul_file "SOUL.md"
  @user_file "USER.md"
  @bootstrap_file "BOOTSTRAP.md"
  @memory_file "MEMORY.md"
  @history_file "HISTORY.md"
  @templates_dir "pincer/templates"

  @doc """
  The base directory for all workspaces. Configurable via `:pincer, :workspaces_dir`.
  """
  @spec base_dir() :: String.t()
  def base_dir do
    Application.get_env(:pincer, :workspaces_dir, "workspaces")
  end

  @doc """
  The path to the special `.template` workspace.
  """
  @spec template_workspace() :: String.t()
  def template_workspace do
    Path.join(base_dir(), ".template")
  end

  @default_memory_md """
  # Long-term Memory

  This file stores curated long-term memory for Pincer.
  """
  @default_history_md """
  # Session History

  This file stores structured recent session snapshots before consolidation.
  """

  @type ensure_option ::
          {:bootstrap?, boolean()}
          | {:inherit_from, String.t()}
          | {:template_root, String.t() | false | nil}

  @doc """
  Returns the workspace root for a given agent or session id.
  """
  @spec workspace_root(String.t() | atom()) :: String.t()
  def workspace_root(agent_id), do: Path.join(base_dir(), to_string(agent_id))

  @doc """
  Returns the `.pincer/` directory inside a workspace.
  """
  @spec pincer_dir(String.t()) :: String.t()
  def pincer_dir(workspace_path), do: Path.join(workspace_path, @pincer_dir)

  @spec sessions_dir(String.t()) :: String.t()
  def sessions_dir(workspace_path), do: Path.join(pincer_dir(workspace_path), @sessions_dir)

  @spec identity_path(String.t()) :: String.t()
  def identity_path(workspace_path), do: Path.join(pincer_dir(workspace_path), @identity_file)

  @spec soul_path(String.t()) :: String.t()
  def soul_path(workspace_path), do: Path.join(pincer_dir(workspace_path), @soul_file)

  @spec user_path(String.t()) :: String.t()
  def user_path(workspace_path), do: Path.join(pincer_dir(workspace_path), @user_file)

  @spec bootstrap_path(String.t()) :: String.t()
  def bootstrap_path(workspace_path), do: Path.join(pincer_dir(workspace_path), @bootstrap_file)

  @spec memory_path(String.t()) :: String.t()
  def memory_path(workspace_path), do: Path.join(pincer_dir(workspace_path), @memory_file)

  @spec history_path(String.t()) :: String.t()
  def history_path(workspace_path), do: Path.join(pincer_dir(workspace_path), @history_file)

  @spec session_log_path(String.t(), String.t()) :: String.t()
  def session_log_path(workspace_path, session_id) do
    safe_id = String.replace(to_string(session_id), ~r/[^a-zA-Z0-9_-]/, "_")
    Path.join(sessions_dir(workspace_path), "session_#{safe_id}.md")
  end

  @doc """
  Ensures that a workspace contains the `.pincer/` runtime scaffold.
  """
  @spec ensure_workspace!(String.t(), [ensure_option()]) :: String.t()
  def ensure_workspace!(workspace_path, opts \\ []) when is_binary(workspace_path) do
    File.mkdir_p!(workspace_path)
    File.mkdir_p!(pincer_dir(workspace_path))
    File.mkdir_p!(sessions_dir(workspace_path))

    seed_memory_files(workspace_path, opts)
    inherit_persona(workspace_path, Keyword.get(opts, :inherit_from))

    if Keyword.get(opts, :bootstrap?, true) do
      seed_root_persona(workspace_path, opts)
    else
      remove_bootstrap(workspace_path)
    end

    workspace_path
  end

  @doc """
  Returns `true` when bootstrap instructions should still be injected for this workspace.
  """
  @spec bootstrap_active?(String.t(), keyword()) :: boolean()
  def bootstrap_active?(workspace_path, opts \\ []) when is_binary(workspace_path) do
    bootstrap? = Keyword.get(opts, :bootstrap?, true)
    bootstrap_file = Keyword.get(opts, :bootstrap_path, bootstrap_path(workspace_path))

    bootstrap? and File.exists?(bootstrap_file) and
      not (File.exists?(identity_path(workspace_path)) and File.exists?(soul_path(workspace_path)))
  end

  @doc """
  Reads a workspace-local markdown file, returning `""` when absent.
  """
  @spec read_file(String.t()) :: String.t()
  def read_file(path) when is_binary(path) do
    if File.exists?(path), do: File.read!(path), else: ""
  end

  @doc """
  Default bootstrap scaffold for new root agents.
  """
  @spec default_bootstrap() :: String.t()
  def default_bootstrap do
    case priv_template(@bootstrap_file) do
      {:ok, content} -> content
      :error -> "# Bootstrap\n\nWelcome! Please introduce yourself.\n"
    end
  end

  @doc """
  Default long-term memory scaffold.
  """
  @spec default_memory() :: String.t()
  def default_memory, do: String.trim(@default_memory_md) <> "\n"

  @doc """
  Default rolling history scaffold.
  """
  @spec default_history() :: String.t()
  def default_history, do: String.trim(@default_history_md) <> "\n"

  defp seed_memory_files(workspace_path, opts) do
    template_root = Keyword.get(opts, :template_root)

    seed_file_from_sources(
      memory_path(workspace_path),
      [template_file(template_root, @memory_file), priv_template_path(@memory_file)],
      default_memory()
    )

    seed_file_from_sources(
      history_path(workspace_path),
      [template_file(template_root, @history_file), priv_template_path(@history_file)],
      default_history()
    )
  end

  defp inherit_persona(_workspace_path, nil), do: :ok

  defp inherit_persona(workspace_path, parent_workspace) when is_binary(parent_workspace) do
    copy_if_missing(identity_path(parent_workspace), identity_path(workspace_path))
    copy_if_missing(soul_path(parent_workspace), soul_path(workspace_path))
    copy_if_missing(user_path(parent_workspace), user_path(workspace_path))
  end

  defp seed_root_persona(workspace_path, opts) do
    template_root = Keyword.get(opts, :template_root)

    seed_file_from_sources(
      identity_path(workspace_path),
      [template_file(template_root, @identity_file), priv_template_path(@identity_file)],
      nil
    )

    seed_file_from_sources(
      soul_path(workspace_path),
      [template_file(template_root, @soul_file), priv_template_path(@soul_file)],
      nil
    )

    seed_file_from_sources(
      user_path(workspace_path),
      [template_file(template_root, @user_file), priv_template_path(@user_file)],
      nil
    )

    seed_file_from_sources(
      bootstrap_path(workspace_path),
      [template_file(template_root, @bootstrap_file), priv_template_path(@bootstrap_file)],
      if(bootstrap_active?(workspace_path, bootstrap_path: bootstrap_path(workspace_path)),
        do: default_bootstrap(),
        else: nil
      )
    )

    if not File.exists?(bootstrap_path(workspace_path)) and
         not (File.exists?(identity_path(workspace_path)) and
                File.exists?(soul_path(workspace_path))) do
      File.write!(bootstrap_path(workspace_path), default_bootstrap())
    end
  end

  defp remove_bootstrap(workspace_path) do
    bootstrap = bootstrap_path(workspace_path)

    if File.exists?(bootstrap) do
      File.rm!(bootstrap)
    end

    :ok
  end

  defp seed_file_from_sources(destination, sources, fallback_content) do
    if not File.exists?(destination) do
      source =
        Enum.find(sources, fn candidate ->
          is_binary(candidate) and File.exists?(candidate)
        end)

      cond do
        is_binary(source) ->
          copy_if_missing(source, destination)

        is_binary(fallback_content) ->
          File.mkdir_p!(Path.dirname(destination))
          File.write!(destination, fallback_content)

        true ->
          :ok
      end
    else
      :ok
    end
  end

  defp copy_if_missing(source, destination) do
    if File.exists?(source) and not File.exists?(destination) do
      File.mkdir_p!(Path.dirname(destination))
      File.cp!(source, destination)
    end

    :ok
  end

  defp template_file(root, filename) when is_binary(root) do
    Path.join([root, ".template", @pincer_dir, filename])
  end

  defp template_file(_root, _filename), do: nil

  @doc false
  @spec priv_template_path(String.t()) :: String.t() | nil
  def priv_template_path(filename) do
    case :code.priv_dir(:pincer) do
      {:error, _} -> nil
      priv -> Path.join([to_string(priv), @templates_dir, filename])
    end
  end

  defp priv_template(filename) do
    case priv_template_path(filename) do
      nil -> :error
      path -> if File.exists?(path), do: {:ok, File.read!(path)}, else: :error
    end
  end
end
