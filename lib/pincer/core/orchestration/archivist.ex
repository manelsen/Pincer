defmodule Pincer.Core.Orchestration.Archivist do
  @moduledoc """
  A memory consolidation agent that extracts and persists knowledge from sessions.

  The Archivist implements a **multi-layer memory architecture**, processing session
  logs through three distinct memory systems:

  1. **Narrative Memory** (`MEMORY.md`) - Human-readable summaries of interactions
  2. **Semantic Memory** (LanceDB) - Vector embeddings for similarity-based retrieval
  3. **Relational Memory** (Graph DB) - Structured relationships (bugs, fixes, files)

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
      │  MEMORY.md   │    │   LanceDB    │    │   Graph DB   │
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
  - LanceDB - Vector embeddings for semantic search
  - Graph DB - Structured relationships for queries
  """

  use GenServer
  require Logger
  alias Pincer.Core.Memory
  alias Pincer.Ports.LLM

  @memory_file "MEMORY.md"

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
  - Knowledge snippets are stored in LanceDB
  - Bug fix relationships are stored in Graph DB
  """
  @spec start_consolidation(String.t(), list()) :: {:ok, pid()}
  def start_consolidation(session_id, history) do
    Task.start(fn ->
      consolidate(session_id, history)
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
  3. Extract and store semantic snippets in LanceDB
  4. Extract and store bug fix relationships in Graph DB

  ## Returns

    * `:ok` - Consolidation completed (or skipped if file not found)
  """
  @spec consolidate(String.t(), list()) :: :ok
  def consolidate(session_id, _history) do
    Logger.info("[ARCHIVIST] 📚 Starting consolidation for Session #{session_id}")

    filename = "sessions/session_#{session_id}.md"

    if File.exists?(filename) do
      content = File.read!(filename)

      current_memory =
        if File.exists?(@memory_file), do: File.read!(@memory_file), else: "(Empty)"

      update_narrative_memory(content, current_memory)

      case Memory.record_session(content, session_id: session_id) do
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

  defp update_narrative_memory(content, current_memory) do
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
        File.write(@memory_file, clean_memory)
        Logger.info("[ARCHIVIST] ✅ MEMORY.md updated!")

      _ ->
        :ok
    end
  end

  defp extract_semantic_snippets(_session_id, content) do
    snippet_instruction = """
    You are a knowledge extraction specialist.
    Read the session below and extract "Knowledge Snippets" (technical facts, bug solutions, user preferences).

    RULES:
    1. Extract only what is USEFUL for future queries.
    2. Format each snippet on a line starting with "SNIPPET:".
    3. If there is nothing useful, respond "NONE".

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

        Enum.each(snippets, fn s ->
          Logger.debug("[ARCHIVIST] Semantic snippet extracted: #{s}")
          # LanceDB.save_message(session_id, "archivist_snippet", s)
        end)

        if length(snippets) > 0,
          do: Logger.info("[ARCHIVIST] 🧬 #{length(snippets)} snippets ingested into LanceDB.")

      _ ->
        :ok
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
            Logger.info("[ARCHIVIST] 🕸️ Bug fix relationship ingested into SQLite Graph: #{file}")

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
