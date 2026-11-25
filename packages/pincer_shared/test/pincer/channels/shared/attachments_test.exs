defmodule Pincer.Channels.Shared.AttachmentsTest do
  use ExUnit.Case, async: true

  alias Pincer.Channels.Shared.Attachments
  alias PincerPorts.Structs.IncomingMessage

  describe "filename and metadata normalization" do
    test "sanitize_filename/1 removes unsafe characters and handles non-binaries" do
      assert Attachments.sanitize_filename("report<1>&\"\n.pdf") == "report_1____.pdf"
      assert Attachments.sanitize_filename(nil) == "attachment"
      assert Attachments.sanitize_filename("") == "attachment"
    end

    test "normalize_size/1 and validate_size/2 enforce limits cleanly" do
      assert Attachments.normalize_size(1200) == 1200
      assert Attachments.normalize_size(" 42 ") == 42
      assert Attachments.normalize_size(-5) == 0
      assert Attachments.normalize_size("invalid") == 0

      assert Attachments.validate_size(100, 100) == :ok
      assert Attachments.validate_size(101, 100) == {:error, :too_large}
    end

    test "extension and content-type classification" do
      assert Attachments.text_extension?("notes.MD")
      assert Attachments.text_extension?(".ex")
      refute Attachments.text_extension?("photo.png")

      assert Attachments.valid_text_content_type?("text/plain; charset=utf-8")
      assert Attachments.valid_text_content_type?("application/json")
      refute Attachments.valid_text_content_type?("application/octet-stream")

      assert Attachments.multimodal_mime(".png") == "image/png"
      assert Attachments.resolve_mime(nil, "doc.pdf") == "application/pdf"
      assert Attachments.resolve_mime("text/csv", "data.csv") == "text/csv"
      assert Attachments.resolve_mime(nil, "archive.zip") == "application/octet-stream"

      assert Attachments.multimodal_extension?(".log", "application/octet-stream",
               extra_mimes: %{".log" => "text/plain"}
             )

      assert Attachments.multimodal_extension?(".csv", "text/csv", allow_text_mime: true)
    end
  end

  describe "reference builders and incoming message conversion" do
    test "build_ref/5 creates normalized attachment_ref and workspace_file_ref maps" do
      ref =
        Attachments.build_ref(
          "telegram://file/abc",
          "bad<name>.pdf",
          "application/pdf",
          "256"
        )

      assert ref == %{
               "type" => "attachment_ref",
               "url" => "telegram://file/abc",
               "mime_type" => "application/pdf",
               "filename" => "bad_name_.pdf",
               "size" => 256
             }

      workspace_ref =
        Attachments.build_ref("telegram://file/xyz", "data.zip", "application/zip", 10,
          type: "workspace_file_ref"
        )

      assert workspace_ref["type"] == "workspace_file_ref"
    end

    test "largest_photo/1 picks largest map by file_size" do
      assert is_nil(Attachments.largest_photo([]))
      assert is_nil(Attachments.largest_photo(nil))

      photos = [
        %{"file_id" => "sm", "file_size" => 100},
        %{"file_id" => "lg", "file_size" => 900},
        %{file_id: "md", file_size: 400}
      ]

      assert Attachments.largest_photo(photos) == %{"file_id" => "lg", "file_size" => 900}
    end

    test "combine_content/3 and to_incoming_message/2 preserve text, attachment_ref, and workspace_file_ref" do
      assert :empty == Attachments.combine_content("", "", [])
      assert {:ok, "hello"} == Attachments.combine_content("hello", "", [])

      att_ref = %{"type" => "attachment_ref", "url" => "https://example.test/a.png"}
      ws_ref = %{"type" => "workspace_file_ref", "url" => "telegram://file/b.zip"}

      assert {:ok, parts} = Attachments.combine_content("caption", "", [att_ref, ws_ref])

      incoming = Attachments.to_incoming_message("s-1", parts)
      assert %IncomingMessage{session_id: "s-1", text: "caption"} = incoming
      assert incoming.attachments == [att_ref, ws_ref]
    end
  end

  describe "list processing and large code-block auto-attachment" do
    test "process_list/2 delegates text download, builds multimodal refs, and notes unsupported files" do
      attachments = [
        %{filename: "notes.txt", size: 12, url: "https://cdn.test/notes.txt"},
        %{filename: "pic.png", size: 200, url: "https://cdn.test/pic.png"},
        %{filename: "archive.bin", size: 50, url: "https://cdn.test/archive.bin"}
      ]

      {text, refs} =
        Attachments.process_list(attachments,
          download_text: fn att -> Attachments.format_inline_file(att.filename, "inline") end
        )

      assert text =~ "[Attachment: notes.txt (12 bytes)]"
      assert text =~ "--- Content of notes.txt ---\ninline\n--- End of File ---"
      assert text =~ "[Attachment: archive.bin (50 bytes)] (unsupported format)"
      assert [%{"type" => "attachment_ref", "mime_type" => "image/png"}] = refs
    end

    test "extract_large_code_blocks/3 extracts large code fences into files" do
      short = "hello ```ex\nIO.puts(:ok)\n```"
      assert {^short, []} = Attachments.extract_large_code_blocks(short)

      big_code = String.duplicate("x", 1100)
      prose = String.duplicate("word ", 120) <> "\n```elixir\n#{big_code}\n```"

      {remaining, [file]} = Attachments.extract_large_code_blocks(prose)
      assert file == %{name: "code_block.elixir", body: big_code}
      assert remaining =~ "📎 *[Content sent in attachment: code_block.elixir]*"
      refute remaining =~ big_code
    end
  end
end
