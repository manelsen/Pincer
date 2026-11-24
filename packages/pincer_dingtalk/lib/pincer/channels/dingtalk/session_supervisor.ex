defmodule Pincer.Channels.DingTalk.SessionSupervisor do
  @moduledoc """
  Dynamic supervisor for per-chat DingTalk delivery workers.
  """
  use DynamicSupervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  @spec start_session(String.t(), String.t()) :: DynamicSupervisor.on_start_child()
  def start_session(chat_id, session_id) do
    DynamicSupervisor.start_child(
      __MODULE__,
      {Pincer.Channels.DingTalk.Session, %{chat_id: chat_id, session_id: session_id}}
    )
  end
end
