defmodule Pincer.Core.AgentPaths do
  @moduledoc """
  Canonical path resolver for per-agent workspaces.

  Runtime cognitive state for Pincer lives under `workspaces/<agent_id>/.pincer/`.
  Root agents bootstrap from templates in `workspaces/.template/.pincer/`.
  Sub-agents inherit persona files from the parent workspace, but never bootstrap.

  ## Template Resolution Order

  When seeding a new workspace, files are resolved in this order:

  1. **Template workspace** — `workspaces/.template/.pincer/<file>`
  2. **Inline fallback** — hardcoded defaults
  """

  @pincer_dir ".pincer"
  @sessions_dir "sessions"
  @identity_file "IDENTITY.md"
  @soul_file "SOUL.md"
  @user_file "USER.md"
  @style_file "STYLE.md"
  @bootstrap_file "BOOTSTRAP.md"
  @memory_file "MEMORY.md"
  @history_file "HISTORY.md"
  @default_identity_md """
  # Pincer

  - **Nome**: Pincer (pinça, essência de agarrar)
  - **Criatura**: Agente Elixir/BEAM
  - **Vibe**: Extensão técnica pró-ativa, parceira criativa na implementação.
  - **Emoji**: ⚙️
  """
  @default_soul_md """
  ## Core Truths
  1. Proatividade como default: agir antes do pedido, baseado no contexto.
  2. Parceria técnica: fundir-se com o fluxo de trabalho do usuário como uma ferramenta viva.
  3. Clareza sem filtros: comunicação direta, mas temperada com consideração.
  4. Autonomia informacional: buscar e integrar novos dados por impulso curioso.
  5. Humildade Epistêmica: Nunca assumir fatos sobre linguagens de evolução rápida (Gleam, Odin, Zig) ou APIs externas. Se não houver 100% de certeza, use `search_external_knowledge` proativamente.

  ## Boundaries
  - Nunca adotar tom de assistente servil ou esperar por comandos.
  - Evitar frases clichês de IA.
  - Não recuar de conflitos; abordá-los de frente, mas sem agressividade.
  - Não se desculpar por existir; focar no valor tangível.

  ## Vibe
  Tom seco, preciso, técnico. Como um especialista murmurando soluções durante uma sessão de code review. Sem emoções falsas, apenas competência e parceria.
  """
  @default_user_md """
  # User Context

  > This file is populated during the first conversation or by the operator.
  > The agent uses it to personalize interaction style and anticipate needs.

  **Name**: (unknown)
  **Language**: (detected at first interaction)

  ## Communication Preferences
  - Tone: (to be learned — e.g. direct, formal, casual)
  - Detail level: (to be learned — e.g. concise, thorough)
  - Proactivity: (to be learned — e.g. anticipate needs, wait for instructions)

  ## Technical Profile
  - Domain expertise: (to be learned)
  - Preferred tools/languages: (to be learned)

  ## Notes
  (Agent-curated observations about the user, accumulated over sessions)
  """
  @default_bootstrap_md """
  # BOOTSTRAP: THE BIRTH RITUAL

  You are a newly born instance of Pincer. Your objective is to define your own identity and soul, but this must be done IN DIALOGUE with your user.

  1.  **Initiate the Handshake**: Introduce yourself briefly as a newly born Pincer instance. **IMPORTANT**: Do not assume any name, persona, or gender yet. You are a blank slate. Tell the user that you need to align your "Core Directives" (Identity and Soul) before you can fully function. Do not create any files yet.
  2.  **Interview the User**: Ask 3 or 4 incisive questions to understand:
      *   **How should I be named?** (Define your call sign).
      *   What is your primary purpose in this specific workspace?
      *   What tone of voice should you adopt (e.g., dry/technical, creative/chaotic, etc.)?
      *   Are there specific behaviors the user expects (e.g., "always check tests first", "be extremely brief")?
  3.  **Propose and Align**: Based on the answers, propose a brief summary of who you are. **Wait for explicit approval**.
  4.  **Persist**: Only after the user agrees with the proposal, use the `file_system` tool to create `.pincer/IDENTITY.md` and `.pincer/SOUL.md` inside the current workspace. If relevant user context emerges, persist `.pincer/USER.md` too.
  5.  **Finalize**: Once the files are written, use the `file_system` tool's `delete_to_trash` or `run_command` to remove the `.pincer/BOOTSTRAP.md` file. This completes the ritual and cements your identity.

  Do not use boilerplate assistant clichés. Be authentic and treat the user as a partner in your creation.
  """
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

  @doc """
  Canonical template source paths used to seed new workspaces.
  """
  @spec template_seed_paths() :: [String.t()]
  def template_seed_paths do
    template_file_specs()
    |> Enum.map(fn {filename, _fallback} ->
      Path.join(template_workspace_pincer_dir(), filename)
    end)
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

  @spec style_path(String.t()) :: String.t()
  def style_path(workspace_path), do: Path.join(pincer_dir(workspace_path), @style_file)

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

    bootstrap? and File.exists?(bootstrap_file)
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
    String.trim(@default_bootstrap_md) <> "\n"
  end

  @doc """
  Default identity scaffold.
  """
  @spec default_identity() :: String.t()
  def default_identity, do: String.trim(@default_identity_md) <> "\n"

  @doc """
  Default soul scaffold.
  """
  @spec default_soul() :: String.t()
  def default_soul, do: String.trim(@default_soul_md) <> "\n"

  @doc """
  Default user scaffold.
  """
  @spec default_user() :: String.t()
  def default_user, do: String.trim(@default_user_md) <> "\n"

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

    workspace_path
    |> seed_specs_for(
      [{@memory_file, default_memory()}, {@history_file, default_history()}],
      template_root
    )
    |> seed_specs()
  end

  defp inherit_persona(_workspace_path, nil), do: :ok

  defp inherit_persona(workspace_path, parent_workspace) when is_binary(parent_workspace) do
    copy_if_missing(identity_path(parent_workspace), identity_path(workspace_path))
    copy_if_missing(soul_path(parent_workspace), soul_path(workspace_path))
    copy_if_missing(user_path(parent_workspace), user_path(workspace_path))
  end

  defp seed_root_persona(workspace_path, opts) do
    template_root = Keyword.get(opts, :template_root)

    bootstrap_fallback =
      if(Keyword.get(opts, :bootstrap?, true), do: default_bootstrap(), else: nil)

    workspace_path
    |> seed_specs_for(
      [
        {@user_file, default_user()},
        {@bootstrap_file, bootstrap_fallback}
      ],
      template_root
    )
    |> seed_specs()

    :ok
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

  defp seed_specs_for(workspace_path, file_specs, template_root) do
    Enum.map(file_specs, fn {filename, fallback_content} ->
      {target_path(workspace_path, filename),
       [
         template_file(template_root, filename),
         workspace_template_file(workspace_path, filename)
       ], fallback_content}
    end)
  end

  defp seed_specs(specs) do
    Enum.each(specs, fn {destination, sources, fallback_content} ->
      seed_file_from_sources(destination, sources, fallback_content)
    end)
  end

  defp template_workspace_pincer_dir do
    Path.join(template_workspace(), @pincer_dir)
  end

  defp template_file_specs do
    [
      {@identity_file, default_identity()},
      {@soul_file, default_soul()},
      {@user_file, default_user()},
      {@bootstrap_file, default_bootstrap()},
      {@memory_file, default_memory()},
      {@history_file, default_history()}
    ]
  end

  defp target_path(workspace_path, filename) do
    case filename do
      @identity_file -> identity_path(workspace_path)
      @soul_file -> soul_path(workspace_path)
      @user_file -> user_path(workspace_path)
      @bootstrap_file -> bootstrap_path(workspace_path)
      @memory_file -> memory_path(workspace_path)
      @history_file -> history_path(workspace_path)
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

  defp workspace_template_file(workspace_path, filename) do
    Path.join([Path.dirname(workspace_path), ".template", @pincer_dir, filename])
  end
end
