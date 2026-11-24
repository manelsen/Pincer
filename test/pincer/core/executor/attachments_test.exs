defmodule Pincer.Core.Executor.AttachmentsTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.Executor.Attachments

  @max_inline_bytes Application.compile_env(:pincer, :max_inline_bytes, 6_291_456)

  describe "default_fetch/2" do
    test "downloads a pinned public URL and base64 encodes the body" do
      parent = self()

      http_client = fn url, opts ->
        send(parent, {:fetch, url, opts})
        {:ok, %Req.Response{status: 200, body: "attachment-body"}}
      end

      assert {:ok, encoded} =
               Attachments.default_fetch("https://93.184.216.34/file.txt",
                 http_client: http_client
               )

      assert Base.decode64!(encoded) == "attachment-body"
      assert_received {:fetch, "https://93.184.216.34/file.txt", opts}
      assert opts[:connect_options][:hostname] == "93.184.216.34"
      assert opts[:decode_body] == false
      assert is_function(opts[:into], 2)
    end

    test "rejects internal URLs before downloading" do
      http_client = fn _url, _opts -> flunk("must not fetch internal URL") end

      assert {:error, reason} =
               Attachments.default_fetch("http://127.0.0.1/secret", http_client: http_client)

      assert reason =~ "internal hosts"
    end

    test "halts oversized downloads while streaming" do
      parent = self()

      http_client = fn _url, opts ->
        body = String.duplicate("a", @max_inline_bytes + 1)
        response = %Req.Response{status: 200, body: ""}

        case opts[:into].({:data, body}, {nil, response}) do
          {:halt, {_request, response}} ->
            send(parent, :halted)
            {:ok, response}

          {:cont, _acc} ->
            flunk("expected the oversized body to halt the download")
        end
      end

      assert {:error, :attachment_too_large} =
               Attachments.default_fetch("https://93.184.216.34/huge.bin",
                 http_client: http_client
               )

      assert_received :halted
    end
  end

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
