defmodule Pincer.Core.Dispatcher do
  @moduledoc """
  Despachante Central.
  Roteia mensagens para o canal correto baseado no ID da sessão.
  """
  require Logger
  alias Pincer.Channels.Telegram
  alias Pincer.Channels.CLI

  def dispatch(session_id, message) do
    case String.split(session_id, "_", parts: 2) do
      ["telegram", chat_id_str] ->
        # Converte para integer pois Telegex espera números
        case Integer.parse(chat_id_str) do
          {chat_id, _} -> Telegram.send_message(chat_id, message)
          :error -> Telegram.send_message(chat_id_str, message)
        end

      ["cli", _user_id] ->
        # Manda para o canal CLI
        CLI.send_message(session_id, message)

      _ ->
        Logger.warning("Canal desconhecido para session_id: #{session_id}")
        :error
    end
  end
end
