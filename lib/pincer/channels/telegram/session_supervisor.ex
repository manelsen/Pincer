defmodule Pincer.Channels.Telegram.SessionSupervisor do
  use DynamicSupervisor

  def start_link(_arg) do
    DynamicSupervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_session(chat_id) do
    spec = {Pincer.Channels.Telegram.Session, chat_id}
    DynamicSupervisor.start_child(__MODULE__, spec)
  end
end
