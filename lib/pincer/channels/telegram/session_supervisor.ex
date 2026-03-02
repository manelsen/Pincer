defmodule Pincer.Channels.Telegram.SessionSupervisor do
  use DynamicSupervisor

  def start_link(_arg) do
    DynamicSupervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_session(chat_id, session_id \\ nil) do
    spec =
      if is_binary(session_id) and session_id != "" do
        {Pincer.Channels.Telegram.Session, %{chat_id: chat_id, session_id: session_id}}
      else
        {Pincer.Channels.Telegram.Session, chat_id}
      end

    DynamicSupervisor.start_child(__MODULE__, spec)
  end
end
