defmodule Pincer.Test.Stubs.Telegram do
  @behaviour Pincer.Channels.Telegram.API

  @impl true
  def get_updates(_opts), do: {:ok, []}

  @impl true
  def get_file(_file_id), do: {:ok, %{file_path: "test/file.txt"}}

  # Non-behaviour helper kept for compatibility with legacy test helpers.
  def get_me, do: {:ok, %{id: 123, username: "test_bot"}}

  @impl true
  def delete_webhook, do: {:ok, true}

  @impl true
  def send_message(_chat_id, _text, _opts), do: {:ok, %{message_id: 123}}

  @impl true
  def edit_message_text(_chat_id, _msg_id, _text, _opts), do: {:ok, %{message_id: 123}}

  @impl true
  def set_my_commands(_commands, _opts), do: {:ok, true}
end
