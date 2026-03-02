defmodule Pincer.Channels.Telegram.API do
  @moduledoc """
  Behavior for Telegram API interactions via Telegex.
  """
  @callback delete_webhook() :: {:ok, boolean()} | {:error, any()}
  @callback get_updates(opts :: keyword()) :: {:ok, [map()]} | {:error, any()}
  @callback send_message(chat_id :: integer() | String.t(), text :: String.t(), opts :: keyword()) :: {:ok, any()} | {:error, any()}
  @callback edit_message_text(chat_id :: integer() | String.t(), message_id :: integer(), text :: String.t(), opts :: keyword()) :: {:ok, any()} | {:error, any()}
  @callback set_my_commands(commands :: [map()], opts :: keyword()) :: {:ok, boolean()} | {:error, any()}
end

defmodule Pincer.Channels.Telegram.API.Adapter do
  @moduledoc """
  Real implementation of Telegram API using Telegex.
  """
  @behaviour Pincer.Channels.Telegram.API

  @impl true
  def delete_webhook(), do: Telegex.delete_webhook()

  @impl true
  def get_updates(opts), do: Telegex.get_updates(opts)

  @impl true
  def send_message(chat_id, text, opts), do: Telegex.send_message(chat_id, text, opts)

  @impl true
  def edit_message_text(chat_id, message_id, text, opts) do
    Telegex.edit_message_text(text, Keyword.merge(opts, chat_id: chat_id, message_id: message_id))
  end

  @impl true
  def set_my_commands(commands, opts \\ []), do: Telegex.set_my_commands(commands, opts)
end
