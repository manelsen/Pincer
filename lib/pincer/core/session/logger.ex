defmodule Pincer.Core.Session.Logger do
  @moduledoc """
  Episodic Memory recorder for session interactions.

  Provides persistent, human-readable logging of all conversation exchanges
  to Markdown files. Each session gets its own log file, creating a searchable
  record of the interaction history.

  ## Purpose

  While `Pincer.Storage` handles structured message persistence for LLM context,
  this logger creates narrative-style logs suitable for:

  - Human review and auditing
  - Debugging conversation flows
  - Post-session analysis
  - Historical reference

  ## File Structure

  Logs are stored in the `sessions/` directory with sanitized filenames:

      sessions/
      ├── session_user_123.md
      ├── session_user_456.md
      └── session_project_alpha.md

  ## Log Format

  Each entry follows a consistent Markdown structure:

      ## [2024-02-19 14:32:15.123456Z] USER

      Create a todo application for my project

      ---

      ## [2024-02-19 14:32:18.456789Z] ASSISTANT

      I'll help you create a todo application...

      ---

  ## Examples

      # Log a user message
      :ok = Pincer.Core.Session.Logger.log("user_123", "user", "Hello, Pincer!")

      # Log an assistant response
      :ok = Pincer.Core.Session.Logger.log("user_123", "assistant", "Hello! How can I help?")

      # Log system-level information
      :ok = Pincer.Core.Session.Logger.log("user_123", "system", "Session started")

  ## Filename Sanitization

  Session IDs are sanitized to ensure filesystem safety:

      "user@email.com"  → "session_user_email_com.md"
      "project-alpha-1" → "session_project-alpha-1.md"
      "test/user:123"   → "session_test_user_123.md"

  ## Thread Safety

  Uses `File.write/3` with `:append` mode, which is atomic for reasonable
  message sizes. For high-volume scenarios, consider batching.
  """
  require Logger

  @sessions_dir "sessions"

  @type session_id :: String.t()
  @type role :: String.t()
  @type content :: String.t()

  @doc """
  Appends a timestamped entry to the session's log file.

  Creates the log file if it doesn't exist. Creates the `sessions/` directory
  if necessary.

  ## Parameters

    * `session_id` - Unique session identifier (used for filename)
    * `role` - Originator of the message ("user", "assistant", "system", etc.)
    * `content` - The message content to log

  ## Examples

      # Basic usage
      :ok = Pincer.Core.Session.Logger.log("user_123", "user", "What's the weather?")

      # After logging, file contains:
      # ## [2024-02-19 14:32:15.123456Z] USER
      #
      # What's the weather?
      #
      # ---

  ## Returns

    * `:ok` - Entry written successfully
    * `{:error, reason}` - File write failed

  ## Side Effects

    * Creates `sessions/` directory if it doesn't exist
    * Creates or appends to `sessions/session_{sanitized_id}.md`
  """
  @spec log(session_id(), role(), content()) :: :ok | {:error, term()}
  def log(session_id, role, content) do
    ensure_dir_exists()

    timestamp = DateTime.utc_now() |> DateTime.to_string()
    filename = get_filename(session_id)

    entry = """

    ## [#{timestamp}] #{String.upcase(role)}

    #{content}

    ---
    """

    File.write(filename, entry, [:append])
  end

  @doc false
  @spec ensure_dir_exists() :: :ok
  defp ensure_dir_exists do
    File.mkdir_p!(@sessions_dir)
  end

  @doc false
  @spec get_filename(session_id()) :: String.t()
  defp get_filename(session_id) do
    safe_id = String.replace(session_id, ~r/[^a-zA-Z0-9_-]/, "_")
    Path.join(@sessions_dir, "session_#{safe_id}.md")
  end
end
