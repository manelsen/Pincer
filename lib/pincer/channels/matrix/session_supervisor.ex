defmodule Pincer.Channels.Matrix.SessionSupervisor do
  @moduledoc """
  DynamicSupervisor managing per-room Matrix session workers.

  Each Matrix room gets its own `Pincer.Channels.Matrix.Session` child,
  started on demand via `start_session/2`.
  """

  use DynamicSupervisor

  def start_link(_arg) do
    DynamicSupervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts a session worker for the given room_id and session_id.
  """
  def start_session(room_id, session_id) do
    spec = {Pincer.Channels.Matrix.Session, %{room_id: room_id, session_id: session_id}}
    DynamicSupervisor.start_child(__MODULE__, spec)
  end
end
