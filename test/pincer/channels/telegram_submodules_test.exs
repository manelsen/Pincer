defmodule Pincer.Channels.TelegramSubmodulesTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  import Mox

  alias Pincer.Channels.Telegram
  alias Pincer.Channels.Telegram.APIMock
  alias Pincer.Channels.Telegram.Commands
  alias Pincer.Channels.Telegram.Formatter
  alias Pincer.Channels.Telegram.Media
  alias Pincer.Channels.Telegram.Menu
  alias Pincer.Channels.Telegram.Poller
  alias Pincer.Channels.Telegram.Transport
  alias Pincer.Channels.Telegram.Update

  @telegram_entrypoint "packages/pincer_telegram/lib/pincer/channels/telegram.ex"

  setup do
    previous_api = Application.fetch_env(:pincer, :telegram_api)
    previous_config = Application.fetch_env(:pincer, :telegram_channel_config)
    Application.put_env(:pincer, :telegram_api, APIMock)

    on_exit(fn ->
      case previous_api do
        {:ok, adapter} -> Application.put_env(:pincer, :telegram_api, adapter)
        :error -> Application.delete_env(:pincer, :telegram_api)
      end

      case previous_config do
        {:ok, cfg} -> Application.put_env(:pincer, :telegram_channel_config, cfg)
        :error -> Application.delete_env(:pincer, :telegram_channel_config)
      end
    end)

    verify_on_exit!()
    :ok
  end

  describe "structural decomposition" do
    test "telegram.ex stays under 400 lines of code" do
      line_count =
        @telegram_entrypoint
        |> File.read!()
        |> String.split("\n")
        |> length()
        |> Kernel.-(1)

      assert line_count < 400,
             "Expected #{@telegram_entrypoint} to have < 400 lines, got #{line_count}"
    end

    test "media and menu accumulators avoid ++ list appends" do
      for path <- [
            "packages/pincer_telegram/lib/pincer/channels/telegram/media.ex",
            "packages/pincer_telegram/lib/pincer/channels/telegram/menu.ex",
            "packages/pincer_telegram/lib/pincer/channels/telegram/transport.ex",
            "packages/pincer_telegram/lib/pincer/channels/telegram/formatter.ex"
          ] do
        ast = path |> File.read!() |> Code.string_to_quoted!(file: path)

        {_ast, has_plus_plus?} =
          Macro.prewalk(ast, false, fn
            {:++, _, _} = node, _acc -> {node, true}
            node, acc -> {node, acc}
          end)

        refute has_plus_plus?, "#{path} must not use ++ list accumulation"
      end
    end

    test "decomposed Telegram submodules are loaded and telegram.ex exports expected API" do
      for mod <- [
            Transport,
            Poller,
            Update,
            Commands,
            Menu,
            Media,
            Formatter,
            Pincer.Channels.Telegram.UpdatesProvider
          ] do
        assert Code.ensure_loaded?(mod), "Expected #{inspect(mod)} to be loaded"
      end

      assert function_exported?(Telegram, :start_link, 1)
      assert function_exported?(Telegram, :send_message, 2)
      assert function_exported?(Telegram, :send_message, 3)
      assert function_exported?(Telegram, :update_message, 3)
      assert function_exported?(Telegram, :update_message, 4)
      assert function_exported?(Telegram, :send_document, 2)
      assert function_exported?(Telegram, :send_document, 3)
      assert function_exported?(Telegram, :markdown_to_html, 1)
      assert function_exported?(Telegram, :register_commands, 0)
      assert function_exported?(Telegram, :menu_reply_markup, 0)
      assert function_exported?(Telegram, :api_client, 0)
    end
  end

  describe "Formatter" do
    test "converts markdown and reasoning to Telegram HTML" do
      assert Formatter.markdown_to_html("**bold** and `code`") ==
               "<b>bold</b> and <code>code</code>"

      assert Formatter.prepare_html("<thinking>secret</thinking>\n\nVisible", []) == "Visible"

      assert Formatter.prepare_html("<thinking>secret</thinking>\n\nVisible",
               skip_reasoning_strip: true
             ) =~ "💭 Reasoning"
    end

    test "detects Telegram parse errors and truncates oversized HTML" do
      assert Formatter.parse_error?("Bad Request: can't parse entities: Can't find end tag")
      assert Formatter.parse_error?("Bad Request: can't find end tag starting at byte offset 10")
      refute Formatter.parse_error?("Bad Request: chat not found")

      truncated = Formatter.truncate_html(String.duplicate("a", 50), 10)
      assert String.starts_with?(truncated, "aaaaaaaaaa")
      assert truncated =~ "(truncated)"
    end
  end

  describe "Transport" do
    test "send_message falls back to plain text on HTML parse error" do
      chat_id = 201

      APIMock
      |> expect(:send_message, fn ^chat_id, "<b>broken", opts ->
        assert opts[:parse_mode] == "HTML"

        {:error,
         %Telegex.Error{error_code: 400, description: "Bad Request: can't parse entities"}}
      end)
      |> expect(:send_message, fn ^chat_id, "broken", opts ->
        refute Keyword.has_key?(opts, :parse_mode)
        {:ok, %{message_id: 99}}
      end)

      assert {:ok, 99} = Transport.send_message(chat_id, "<b>broken")
    end

    test "update_message handles not modified, truncation, and parse error fallback" do
      chat_id = 202

      APIMock
      |> expect(:edit_message_text, fn ^chat_id, 1, "same", _opts ->
        {:error,
         %Telegex.Error{error_code: 400, description: "Bad Request: message is not modified"}}
      end)
      |> expect(:edit_message_text, fn ^chat_id, 2, _text, _opts ->
        {:error, %Telegex.Error{error_code: 400, description: "Bad Request: message is too long"}}
      end)
      |> expect(:edit_message_text, fn ^chat_id, 2, truncated, opts ->
        assert opts[:parse_mode] == "HTML"
        assert truncated =~ "(truncated)"
        {:ok, %{}}
      end)

      assert :ok = Transport.update_message(chat_id, 1, "same", skip_formatting: true)
      assert :ok = Transport.update_message(chat_id, 2, String.duplicate("x", 4500))
    end

    test "send_document passes optional caption and normalizes ok/error" do
      chat_id = 203

      APIMock
      |> expect(:send_document, fn ^chat_id, "/tmp/report.pdf", [caption: "Relatorio"] ->
        {:ok, %{}}
      end)
      |> expect(:send_document, fn ^chat_id, "/tmp/missing.pdf", [] ->
        {:error, :enoent}
      end)

      assert :ok = Transport.send_document(chat_id, "/tmp/report.pdf", caption: "Relatorio")
      assert {:error, :enoent} = Transport.send_document(chat_id, "/tmp/missing.pdf")
    end
  end

  describe "Menu" do
    test "menu_reply_markup switches between native and persistent modes" do
      Application.put_env(:pincer, :telegram_channel_config, %{})
      assert %{remove_keyboard: true} = Menu.menu_reply_markup()

      Application.put_env(:pincer, :telegram_channel_config, %{"menu_keyboard" => "persistent"})
      assert %{keyboard: [[%{text: _}]], is_persistent: true} = Menu.menu_reply_markup()
    end

    test "build_provider_buttons preserves provider order and skips oversized payloads" do
      providers = [
        %{id: "groq", name: "Groq"},
        %{id: String.duplicate("x", 200), name: "TooLong"},
        %{id: "openrouter", name: "OpenRouter"}
      ]

      log =
        capture_log(fn ->
          buttons = Menu.build_provider_buttons(providers)

          assert [
                   [%{text: "Groq", callback_data: "select_provider:groq"}],
                   [%{text: "OpenRouter", callback_data: "select_provider:openrouter"}]
                 ] = buttons
        end)

      assert log =~ "Skipping provider button with oversized callback payload"
    end

    test "handle_callback replies gracefully on invalid payload and renders show_menu" do
      chat_id = 204

      APIMock
      |> expect(:send_message, fn ^chat_id, text, opts ->
        assert text =~ "desconhecida ou expirada"
        assert opts[:reply_markup]
        {:ok, %{message_id: 10}}
      end)
      |> expect(:send_message, fn ^chat_id, text, opts ->
        assert is_binary(text) and text != ""
        assert opts[:reply_markup]
        {:ok, %{message_id: 11}}
      end)

      capture_log(fn ->
        assert {:ok, 10} = Menu.handle_callback(chat_id, "private", "invalid:payload", 50)
      end)

      assert {:ok, 11} = Menu.handle_callback(chat_id, "private", "show_menu", 50)
    end
  end

  describe "Commands" do
    test "handles /ping, /menu, and unknown commands" do
      chat_id = 205

      APIMock
      |> expect(:send_message, fn ^chat_id, "Pong! 🏓", _opts ->
        {:ok, %{message_id: 11}}
      end)
      |> expect(:send_message, fn ^chat_id, text, opts ->
        assert is_binary(text) and text != ""
        assert opts[:reply_markup]
        {:ok, %{message_id: 12}}
      end)
      |> expect(:send_message, fn ^chat_id, text, opts ->
        assert text =~ "Unknown command"
        assert text =~ "/nope"
        assert opts[:reply_markup]
        {:ok, %{message_id: 13}}
      end)

      assert {:ok, 11} = Commands.handle(chat_id, "/ping", "", "private")
      assert {:ok, 12} = Commands.handle(chat_id, "/menu", "", "private")
      assert {:ok, 13} = Commands.handle(chat_id, "/nope", "", "private")
    end

    test "register_commands sends policy commands to Telegram API" do
      APIMock
      |> expect(:set_my_commands, fn commands, [] ->
        assert is_list(commands)
        assert commands != []
        {:ok, true}
      end)

      assert :ok = Commands.register_commands()
    end
  end

  describe "Media" do
    test "detects supported attachments and preserves document+photo refs in order" do
      assert Media.has_supported_attachments?(%{photo: [%{"file_id" => "p1"}]})
      assert Media.has_supported_attachments?(%{document: %{"file_id" => "d1"}})
      assert Media.has_supported_attachments?(%{voice: %{"file_id" => "v1"}})
      refute Media.has_supported_attachments?(%{text: "just text"})

      APIMock
      |> expect(:get_file, fn "doc1" -> {:ok, %{file_path: "docs/data.csv"}} end)
      |> expect(:get_file, fn "photo1" -> {:ok, %{file_path: "photos/pic.jpg"}} end)

      message = %{
        caption: "Analyze both",
        document: %{file_id: "doc1", file_name: "data.csv", file_size: 120},
        photo: [%{file_id: "photo1", file_unique_id: "u1", file_size: 400}]
      }

      assert {:ok, parts} = Media.prepare_input_content(message, APIMock)

      assert [
               %{"type" => "text", "text" => "Analyze both"},
               %{"type" => "workspace_file_ref", "filename" => "data.csv"},
               %{"type" => "attachment_ref", "filename" => "photo_u1.jpg"}
             ] = parts
    end

    test "handles oversized document metadata and missing file path errors" do
      APIMock
      |> expect(:get_file, fn "bad_doc" -> {:error, :not_found} end)

      oversized = %{document: %{file_id: "big", file_name: "big.pdf", file_size: 200_000_000}}
      assert {:ok, text} = Media.prepare_input_content(oversized, APIMock)
      assert text =~ "big.pdf"
      assert text =~ "arquivo grande demais"

      failed = %{document: %{file_id: "bad_doc", file_name: "missing.pdf", file_size: 10}}

      log =
        capture_log(fn ->
          assert {:ok, err_text} = Media.prepare_input_content(failed, APIMock)
          assert err_text =~ "missing.pdf"
          assert err_text =~ "erro ao resolver arquivo"
        end)

      assert log =~ "Failed to resolve document attachment"
    end
  end

  describe "Update" do
    test "logs and ignores unsupported updates and malformed messages" do
      previous_level = Logger.level()
      Logger.configure(level: :debug)

      log =
        try do
          capture_log(fn ->
            assert :ok = Update.process(%{unknown_field: 1})
            assert :ok = Update.process(%{message: %{text: "missing chat"}})
          end)
        after
          Logger.configure(level: previous_level)
        end

      assert log =~ "Ignoring unsupported update"
      assert log =~ "Ignoring malformed Telegram message"
    end

    test "dispatches callback_query updates to Menu" do
      chat_id = 206

      APIMock
      |> expect(:send_message, fn ^chat_id, text, opts ->
        assert is_binary(text) and text != ""
        assert opts[:reply_markup]
        {:ok, %{message_id: 14}}
      end)

      assert :ok =
               Update.process(%{
                 callback_query: %{
                   data: "show_menu",
                   message: %{message_id: 1, chat: %{id: chat_id, type: "private"}}
                 }
               })
    end
  end

  describe "Poller" do
    test "calculates exponential backoff and parses delivery messages" do
      assert Poller.next_poll_interval(0) == 1000
      assert Poller.next_poll_interval(1) == 2000
      assert Poller.next_poll_interval(2) == 4000
      assert Poller.next_poll_interval(10) == 30_000

      APIMock
      |> expect(:send_message, fn 555, "Hello from delivery", _opts ->
        {:ok, %{message_id: 77}}
      end)

      assert {:ok, 77} = Poller.deliver_message("telegram_555", "Hello from delivery")
      assert :ignore = Poller.deliver_message("discord_555", "Not telegram")
    end
  end
end
