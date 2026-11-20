defmodule Pincer.Channels.TestAdapter do
  @moduledoc """
  A no-op adapter for use in tests to avoid side effects during startup.
  """

  # Discord API
  @behaviour Pincer.Channels.Discord.API
  @impl true
  def create_message(_channel_id, _content, _opts), do: {:ok, %{}}
  @impl true
  def edit_message(_channel_id, _message_id, _opts), do: {:ok, %{}}
  @impl true
  def create_interaction_response(_id, _token, _response), do: :ok
  @impl true
  def bulk_overwrite_global_commands(_commands), do: {:ok, []}

  # Telegram API
  @behaviour Pincer.Channels.Telegram.API
  @impl true
  def delete_webhook(), do: {:ok, true}
  @impl true
  def get_updates(_opts), do: {:ok, []}
  @impl true
  def get_file(_file_id), do: {:ok, %{file_path: "test/file.txt"}}
  @impl true
  def send_message(_chat_id, _text, _opts), do: {:ok, %{}}
  @impl true
  def send_document(_chat_id, _document, _opts), do: {:ok, %{}}
  @impl true
  def edit_message_text(_chat_id, _message_id, _text, _opts), do: {:ok, %{}}
  @impl true
  def set_my_commands(_commands, _opts), do: {:ok, true}

  # Slack API
  @behaviour Pincer.Channels.Slack.API
  @impl true
  def post(_method, _token, _payload), do: {:ok, %{}}
end
