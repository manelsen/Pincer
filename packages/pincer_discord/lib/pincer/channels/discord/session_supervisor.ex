defmodule Pincer.Channels.Discord.SessionSupervisor do
  @moduledoc """
  DynamicSupervisor managing the lifecycle of Discord session workers.
  """
  use DynamicSupervisor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_session(channel_id, session_id \\ nil) do
    child_spec =
      if is_binary(session_id) and session_id != "" do
        {Pincer.Channels.Discord.Session, %{channel_id: channel_id, session_id: session_id}}
      else
        {Pincer.Channels.Discord.Session, channel_id}
      end

    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end
end
