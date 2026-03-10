defmodule Pincer.Core.Orchestration.Archivist do
  @moduledoc """
  A memory consolidation agent that extracts and persists knowledge from sessions.

  The Archivist implements a **multi-layer memory architecture**, processing session
  logs through three distinct memory systems:

  1. **Narrative Memory** (`MEMORY.md`) - Human-readable summaries of interactions
  2. **Semantic Memory** (Postgres + pgvector) - Vector embeddings for similarity-based retrieval
  3. **Relational Memory** (Postgres Graph Tables) - Structured relationships (bugs, fixes, files)

  ## Memory Architecture

      ┌─────────────────────────────────────────────────────────────┐
      │                    Session Log                              │
      │              (sessions/session_ID.md)                       │
      └─────────────────────────┬───────────────────────────────────┘
                                │ Archivist processes
                                ▼
      ┌─────────────────────────────────────────────────────────────┐
      │                      ARCHIVIST                              │
      │                                                             │
      │   ┌─────────────────────────────────────────────────────┐  │
      │   │ LLM-based extraction:                               │  │
      │   │  1. Summarize for Narrative Memory                  │  │
      │   │  2. Extract knowledge snippets                      │  │
      │   │  3. Identify bug fixes and relationships            │  │
      │   └─────────────────────────────────────────────────────┘  │
      └────────┬────────────────────┬───────────────────┬──────────┘
               │                    │                   │
               ▼                    ▼                   ▼
      ┌──────────────┐    ┌──────────────┐    ┌──────────────┐
      │  MEMORY.md   │    │  pgvector    │    │ Postgres DB  │
      │  (Narrative) │    │  (Semantic)  │    │ (Relational) │
      └──────────────┘    └──────────────┘    └──────────────┘

  ## Trigger Conditions

  The Archivist is typically triggered when:

  - Context window reaches a threshold (e.g., 20% capacity)
  - Session ends
  - Manual consolidation is requested

  ## Consolidation Pipeline

  ### 1. Narrative Memory Update

  Reads current `MEMORY.md` and session log, prompts LLM to:

  - Add new facts (preferences, decisions, context)
  - Ignore trivial conversations
  - Keep content concise

  ### 2. Semantic Snippet Extraction

  Extracts "Knowledge Snippets" for vector storage:

  - Technical facts
  - Bug solutions
  - User preferences
  - Architecture decisions

  ### 3. Relational Graph Extraction

  Identifies and stores bug-fix relationships:

  - Bug description
  - Fix summary
  - Affected file path

  ## Examples

      # Start consolidation asynchronously
      Pincer.Core.Orchestration.Archivist.start_consolidation(
        "session_123",
        conversation_history
      )

      # Or start as a supervised GenServer
      {:ok, pid} = Pincer.Core.Orchestration.Archivist.start_link([])

  ## Memory File Locations

  - `MEMORY.md` - Root of workspace, human-editable
  - `sessions/session_ID.md` - Individual session logs
  - Postgres + pgvector - Vector embeddings for semantic search
  - Postgres graph tables - Structured relationships for queries
  """

  use GenServer
  require Logger
  alias Pincer.Core.AgentPaths
  alias Pincer.Core.Memory
  alias Pincer.Core.MemoryTypes
  alias Pincer.Ports.LLM
  alias Pincer.Ports.Storage

  @user_memory_header "## Learned User Memory"

  @type option :: any()
  @type state :: keyword()

  @doc """
  Starts the Archivist GenServer.

  The Archivist can run as a supervised process or be started transiently
  for one-off consolidation tasks.

  ## Returns

    * `{:ok, pid}` - The Archivist process started successfully

  ## Examples

      iex> Pincer.Core.Orchestration.Archivist.start_link([])
      {:ok, #PID<0.200.0>}

  """
  @spec start_link([option]) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Starts an asynchronous consolidation task.

  This is the primary entry point for triggering memory consolidation.
  The consolidation runs in a separate Task process, allowing the caller
  to continue without blocking.

  ## Parameters

    * `session_id` - The session identifier to consolidate
    * `history` - The conversation history (currently unused, reads from file)

  ## Returns

    * `{:ok, task_pid}` - The consolidation task started successfully

  ## Examples

      iex> Pincer.Core.Orchestration.Archivist.start_consolidation(
      ...>   "session_abc",
      ...>   [%{"role" => "user", "content" => "Hello"}]
      ...> )
      {:ok, #PID<0.201.0>}

  ## Side Effects

  On successful consolidation:

  - `MEMORY.md` is updated with new narrative content
  - Knowledge snippets are stored in Postgres + pgvector
  - Bug fix relationships are stored in Postgres graph tables
  """
  @spec start_consolidation(String.t(), list(), keyword()) :: {:ok, pid()}
  def start_consolidation(session_id, history, opts \\ []) do
    Task.start(fn ->
      consolidate(session_id, history, opts)
    end)
  end

  @doc false
  @impl GenServer
  def init(opts) do
    {:ok, opts}
  end

  @doc """
  Performs the full consolidation pipeline for a session.

  Reads the session log file and processes it through all three memory systems.

  ## Parameters

    * `session_id` - The session identifier
    * `_history` - Conversation history (reserved for future use)

  ## Process Flow

  1. Read `sessions/session_{session_id}.md`
  2. Update `MEMORY.md` with summarized narrative
  3. Extract and store semantic snippets in Postgres + pgvector
  4. Extract and store bug fix relationships in Postgres graph tables

  ## Returns

    * `:ok` - Consolidation completed (or skipped if file not found)
  """
  @spec consolidate(String.t(), list(), keyword()) :: :ok
  def consolidate(session_id, _history, opts \\ []) do
    Logger.info("[ARCHIVIST] 📚 Starting consolidation for Session #{session_id}")

    workspace_path = Keyword.get(opts, :workspace_path, AgentPaths.workspace_root(session_id))
    filename = AgentPaths.session_log_path(workspace_path, session_id)
    memory_path = AgentPaths.memory_path(workspace_path)
    history_path = AgentPaths.history_path(workspace_path)
    user_path = AgentPaths.user_path(workspace_path)

    if File.exists?(filename) do
      content = File.read!(filename)

      current_memory =
        if File.exists?(memory_path), do: File.read!(memory_path), else: "(Empty)"

      current_user = if File.exists?(user_path), do: File.read!(user_path), else: ""

      update_narrative_memory(content, current_memory, memory_path)
      update_user_memory(content, current_user, user_path)

      case Memory.record_session(content,
             session_id: session_id,
             history_path: history_path,
             memory_path: memory_path
           ) do
        {:ok, _report} ->
          :ok

        {:error, reason} ->
          Logger.warning("[ARCHIVIST] Two-layer memory sync failed: #{inspect(reason)}")
      end

      extract_semantic_snippets(session_id, content)
      extract_relational_data(content)
    else
      Logger.warning("[ARCHIVIST] Session file not found: #{filename}")
    end
  end

  defp update_narrative_memory(content, current_memory, memory_path) do
    archive_instruction = """
    You are the ARCHIVIST. Read the session and update MEMORY.md with new facts.
    IGNORE trivial conversations. Keep it concise.

    ## CURRENT MEMORY
    #{current_memory}

    ## RECENT SESSION
    #{content}

    RETURN ONLY THE FILE CONTENT.
    """

    case LLM.chat_completion([%{"role" => "system", "content" => archive_instruction}]) do
      {:ok, %{"content" => new_memory}, _usage} ->
        clean_memory = sanitize_markdown(new_memory)
        File.write(memory_path, clean_memory)
        Logger.info("[ARCHIVIST] ✅ MEMORY.md updated!")

      _ ->
        :ok
    end
  end

  defp extract_semantic_snippets(session_id, content) do
    snippet_instruction = """
    You are a knowledge extraction specialist.
    Read the session below and extract "Knowledge Snippets" (technical facts, bug solutions, user preferences).

    RULES:
    1. Extract only what is USEFUL for future queries.
    2. Format each snippet as: "SNIPPET: [memory_type] | [importance 1-10] | [content]".
    3. Allowed memory_type values: reference, technical_fact, bug_solution, user_preference, architecture_decision, session_summary.
    4. If there is nothing useful, respond "NONE".

    ## SESSION TO PROCESS
    #{content}
    """

    case LLM.chat_completion([%{"role" => "system", "content" => snippet_instruction}]) do
      {:ok, %{"content" => response}, _usage} ->
        snippets =
          response
          |> String.split("\n")
          |> Enum.filter(&String.starts_with?(&1, "SNIPPET:"))
          |> Enum.map(&(String.replace(&1, "SNIPPET:", "") |> String.trim()))
          |> Enum.map(&parse_snippet/1)

        Enum.with_index(snippets, 1)
        |> Enum.each(fn {snippet, index} ->
          vector =
            case LLM.generate_embedding(snippet.content, provider: "openrouter") do
              {:ok, values} when is_list(values) -> values
              _ -> []
            end

          path = "session://#{session_id}/snippet/#{index}"

          Storage.index_memory(
            path,
            snippet.content,
            snippet.memory_type,
            vector,
            importance: snippet.importance,
            session_id: session_id
          )

          Logger.debug("[ARCHIVIST] Semantic snippet extracted: #{snippet.content}")
        end)

        if length(snippets) > 0,
          do:
            Logger.info(
              "[ARCHIVIST] 🧬 #{length(snippets)} snippets ingested into Postgres + pgvector."
            )

      _ ->
        :ok
    end
  end

  defp parse_snippet(raw_snippet) do
    case String.split(raw_snippet, "|", parts: 3) |> Enum.map(&String.trim/1) do
      [memory_type, importance, content] ->
        %{
          memory_type: MemoryTypes.normalize(memory_type),
          importance: parse_importance(importance),
          content: content
        }

      [content] ->
        %{memory_type: "reference", importance: 5, content: content}

      _ ->
        %{memory_type: "reference", importance: 5, content: raw_snippet}
    end
  end

  defp parse_importance(value) do
    case Integer.parse(value) do
      {importance, _} -> min(10, max(0, importance))
      :error -> 5
    end
  end

  defp update_user_memory(content, current_user, user_path) do
    instruction = """
    You extract durable user preferences and constraints.
    Read the session below and extract durable user preferences.

    RULES:
    1. Return only bullet lines starting with "- ".
    2. Include only stable preferences, habits, channels or constraints.
    3. If there is nothing durable, return "NONE".

    ## CURRENT USER FILE
    #{current_user}

    ## SESSION TO PROCESS
    #{content}
    """

    case LLM.chat_completion([%{"role" => "system", "content" => instruction}]) do
      {:ok, %{"content" => response}, _usage} ->
        merged =
          current_user
          |> merge_user_memory(response)
          |> String.trim()

        if merged != "" do
          File.write!(user_path, merged <> "\n")
        end

      _ ->
        :ok
    end
  end

  defp merge_user_memory(existing_user, response) do
    existing_user = String.trim(existing_user)

    bullets =
      response
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&String.starts_with?(&1, "- "))
      |> Enum.uniq()

    cond do
      String.trim(response) == "NONE" ->
        existing_user

      bullets == [] ->
        existing_user

      true ->
        {base, existing_bullets} = split_user_memory(existing_user)

        managed_section =
          @user_memory_header <> "\n" <> Enum.join(Enum.uniq(existing_bullets ++ bullets), "\n")

        cond do
          base == "" -> managed_section
          true -> base <> "\n\n" <> managed_section
        end
    end
  end

  defp split_user_memory(text) do
    case String.split(text, @user_memory_header, parts: 2) do
      [base, managed] ->
        bullets =
          managed
          |> String.split("\n")
          |> Enum.map(&String.trim/1)
          |> Enum.filter(&String.starts_with?(&1, "- "))

        {String.trim(base), bullets}

      _ ->
        {String.trim(text), []}
    end
  end

  defp extract_relational_data(content) do
    graph_instruction = """
    You are a Software Architecture and bug tracking specialist.
    Read the session below and identify if any BUG was fixed.

    RULES:
    1. If a bug was fixed, extract: Bug Description, Fix Summary, and Affected File.
    2. Format as: "BUG_FIX: [bug] | [fix] | [file_path]"
    3. If no bugs were fixed, respond "NONE".

    ## SESSION TO PROCESS
    #{content}
    """

    case LLM.chat_completion([%{"role" => "system", "content" => graph_instruction}]) do
      {:ok, %{"content" => response}, _usage} ->
        case String.split(response, "BUG_FIX:") do
          [_, data] ->
            [bug, fix, file] = data |> String.split("|") |> Enum.map(&String.trim/1)
            Pincer.Ports.Storage.ingest_bug_fix(bug, fix, file)

            Logger.info(
              "[ARCHIVIST] 🕸️ Bug fix relationship ingested into Postgres graph: #{file}"
            )

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end

  @spec sanitize_markdown(String.t()) :: String.t()
  defp sanitize_markdown(text) do
    text
    |> String.replace(~r/^```markdown\s*/, "")
    |> String.replace(~r/^```\s*/, "")
    |> String.replace(~r/\s*```$/, "")
    |> String.trim()
  end
end
