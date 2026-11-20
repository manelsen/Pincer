defmodule Pincer.Core.Executor.AttachmentsTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.Executor.Attachments

  describe "resolve_url/2" do
    test "keeps regular URLs unchanged" do
      assert {:ok, "https://cdn.example.com/file.pdf"} =
               Attachments.resolve_url("https://cdn.example.com/file.pdf", "ignored")
    end

    test "expands telegram://file/ URLs when token is present" do
      assert {:ok, "https://api.telegram.org/file/botabc123/docs/a.txt"} =
               Attachments.resolve_url("telegram://file/docs/a.txt", "abc123")
    end

    test "returns errors for missing telegram token or invalid URL" do
      assert {:error, :telegram_token_missing} =
               Attachments.resolve_url("telegram://file/docs/a.txt", "")

      assert {:error, :invalid_attachment_url} = Attachments.resolve_url(nil, "tok")
    end
  end

  describe "resolve_history/3" do
    test "uses injected file_fetcher directly without reading process dictionary" do
      Process.put(:executor_deps, %{file_fetcher: fn _ -> flunk("must not use Process.get") end})

      on_exit(fn -> Process.delete(:executor_deps) end)

      fetcher = fn "https://example.com/notes.txt" ->
        {:ok, Base.encode64("hello attachment")}
      end

      history = [
        %{
          "role" => "user",
          "content" => [
            %{
              "type" => "attachment_ref",
              "url" => "https://example.com/notes.txt",
              "mime_type" => "text/plain",
              "filename" => "notes.txt",
              "size" => 16
            }
          ]
        }
      ]

      [msg] = Attachments.resolve_history(history, %{}, fetcher)

      assert msg["content"] == [
               %{"type" => "text", "text" => "Content of notes.txt:\nhello attachment"}
             ]
    end

    test "inlines binary attachments when provider supports files and rejects unsupported/oversized" do
      fetcher = fn "https://example.com/a.pdf" -> {:ok, Base.encode64("pdf-bytes")} end

      history = [
        %{
          "role" => "user",
          "content" => [
            %{
              "type" => "attachment_ref",
              "url" => "https://example.com/a.pdf",
              "mime_type" => "application/pdf",
              "filename" => "a.pdf",
              "size" => 100
            },
            %{
              "type" => "attachment_ref",
              "url" => "https://example.com/huge.bin",
              "mime_type" => "application/octet-stream",
              "filename" => "huge.bin",
              "size" => 10_000_000
            }
          ]
        }
      ]

      [supported_msg] = Attachments.resolve_history(history, %{supports_files: true}, fetcher)

      assert Enum.at(supported_msg["content"], 0) == %{
               "type" => "inline_data",
               "mime_type" => "application/pdf",
               "data" => Base.encode64("pdf-bytes")
             }

      assert Enum.at(supported_msg["content"], 1)["text"] =~ "exceeds inline limit"

      [unsupported_msg] = Attachments.resolve_history(history, %{supports_files: false}, fetcher)
      assert Enum.at(unsupported_msg["content"], 0)["text"] =~ "does not support attachments"
    end

    test "returns error text when file_fetcher fails" do
      fetcher = fn _url -> {:error, :timeout} end

      history = [
        %{
          "role" => "user",
          "content" => [
            %{
              "type" => "attachment_ref",
              "url" => "https://example.com/err.txt",
              "mime_type" => "text/plain",
              "filename" => "err.txt",
              "size" => 10
            }
          ]
        }
      ]

      [msg] = Attachments.resolve_history(history, %{}, fetcher)

      assert [%{"type" => "text", "text" => "[Failed to download err.txt: :timeout]"}] =
               msg["content"]
    end
  end
end
