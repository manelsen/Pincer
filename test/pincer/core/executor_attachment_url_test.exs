defmodule Pincer.Core.ExecutorAttachmentUrlTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.Executor

  test "resolve_attachment_url/2 keeps regular URLs unchanged" do
    assert {:ok, "https://cdn.example.com/file.pdf"} =
             Executor.resolve_attachment_url("https://cdn.example.com/file.pdf", "ignored-token")
  end

  test "resolve_attachment_url/2 expands telegram file scheme with token" do
    assert {:ok, "https://api.telegram.org/file/botabc123/photos/file_1.jpg"} =
             Executor.resolve_attachment_url("telegram://file/photos/file_1.jpg", "abc123")
  end

  test "resolve_attachment_url/2 returns error when telegram token is missing" do
    assert {:error, :telegram_token_missing} =
             Executor.resolve_attachment_url("telegram://file/photos/file_1.jpg", "")
  end
end
