defmodule Pincer.Core.Dispatcher do
  @moduledoc """
  Central Dispatcher.
  Routes messages to the correct channel based on session ID.
  """
  require Logger
  alias Pincer.Channels.Telegram
  alias Pincer.Channels.CLI

  def dispatch(session_id, message) do
    case String.split(session_id, "_", parts: 2) do
      ["telegram", chat_id_str] ->
        # Converts to integer since Telegex expects numbers
        case Integer.parse(chat_id_str) do
          {chat_id, _} -> Telegram.send_message(chat_id, message)
          :error -> Telegram.send_message(chat_id_str, message)
        end

      ["cli", _user_id] ->
        # Sends to CLI channel
        CLI.send_message(session_id, message)

      _ ->
        Logger.warning("Unknown channel for session_id: #{session_id}")
        :error
    end
  end
end
