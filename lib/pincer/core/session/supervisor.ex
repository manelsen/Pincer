defmodule Pincer.Core.Session.Supervisor do
  @moduledoc """
  DynamicSupervisor managing the lifecycle of session servers.

  Provides a centralized entry point for creating and terminating user sessions.
  Each session runs as an independent `Pincer.Core.Session.Server` process under this
  supervisor, allowing for fault isolation and dynamic scaling.

  ## Architecture

      ┌─────────────────────────────────────────────────┐
      │            Pincer.Core.Session.Supervisor            │
      │            (DynamicSupervisor)                  │
      └─────────────────────────────────────────────────┘
                           │
          ┌────────────────┼────────────────┐
          ▼                ▼                ▼
    ┌───────────┐    ┌───────────┐    ┌───────────┐
    │ Session 1 │    │ Session 2 │    │ Session N │
    │ (Server)  │    │ (Server)  │    │ (Server)  │
    └───────────┘    └───────────┘    └───────────┘

  ## Restart Strategy

  Uses `:one_for_one` strategy, meaning if a session crashes, only that
  session is restarted. Other sessions are unaffected.

  ## Session Registry

  Sessions are registered in `Pincer.Core.Session.Registry` using their `session_id`,
  enabling process lookup by ID rather than PID.

  ## Examples

      # Start the supervisor (typically done in application supervision tree)
      {:ok, pid} = Pincer.Core.Session.Supervisor.start_link([])

      # Create a new session
      {:ok, session_pid} = Pincer.Core.Session.Supervisor.start_session("user_123")

      # Terminate a session
      :ok = Pincer.Core.Session.Supervisor.stop_session("user_123")

  ## Integration

  The supervisor should be added to your application's supervision tree:

      children = [
        # ... other children
        Pincer.Core.Session.Supervisor
      ]

  Note: Requires `Pincer.Core.Session.Registry` to be started before use.
  """
  use DynamicSupervisor

  @type session_id :: String.t()

  @doc """
  Starts the session supervisor.

  Typically called during application startup as part of the supervision tree.

  ## Parameters

    * `init_arg` - Initialization arguments (currently unused)

  ## Examples

      {:ok, pid} = Pincer.Core.Session.Supervisor.start_link([])

  ## Returns

    * `{:ok, pid}` - Supervisor started successfully
    * `{:error, {:already_started, pid}}` - Supervisor already running
  """
  @spec start_link(term()) :: GenServer.on_start()
  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Creates and starts a new session server.

  Spawns a new `Pincer.Core.Session.Server` process registered under the given
  `session_id`. If a session with that ID already exists, returns an error.

  ## Parameters

    * `session_id` - Unique identifier for the new session

  ## Examples

      {:ok, pid} = Pincer.Core.Session.Supervisor.start_session("user_123")
      #=> {:ok, #PID<0.456.0>}

      # Attempting to start duplicate session
      {:error, {:already_started, pid}} = Pincer.Core.Session.Supervisor.start_session("user_123")

  ## Returns

    * `{:ok, pid}` - Session started successfully
    * `{:ok, pid}` - Session already exists (idempotent behavior from Registry)
    * `{:error, reason}` - Failed to start session
  """
  @spec start_session(session_id()) :: {:ok, pid()} | {:error, term()}
  def start_session(session_id) do
    child_spec = {Pincer.Core.Session.Server, [session_id: session_id]}
    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end

  @doc """
  Terminates an active session.

  Looks up the session process via the Registry and terminates it gracefully.
  The session's conversation history is persisted before termination.

  ## Parameters

    * `session_id` - Identifier of the session to terminate

  ## Examples

      :ok = Pincer.Core.Session.Supervisor.stop_session("user_123")

      # Attempting to stop non-existent session
      {:error, :not_found} = Pincer.Core.Session.Supervisor.stop_session("unknown")

  ## Returns

    * `:ok` - Session terminated successfully
    * `{:error, :not_found}` - No session with given ID exists
  """
  @spec stop_session(session_id()) :: :ok | {:error, :not_found}
  def stop_session(session_id) do
    case Registry.lookup(Pincer.Core.Session.Registry, session_id) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(__MODULE__, pid)
      [] -> {:error, :not_found}
    end
  end
end
