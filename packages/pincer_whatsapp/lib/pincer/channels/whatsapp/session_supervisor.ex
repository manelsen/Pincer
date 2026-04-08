defmodule Pincer.Channels.WhatsApp.SessionSupervisor do
  @moduledoc """
  DynamicSupervisor responsible for WhatsApp session workers.
  """

  use DynamicSupervisor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_session(chat_id, session_id \\ nil) do
    child_spec =
      if is_binary(session_id) and session_id != "" do
        {Pincer.Channels.WhatsApp.Session, %{chat_id: chat_id, session_id: session_id}}
      else
        {Pincer.Channels.WhatsApp.Session, chat_id}
      end

    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end
end
