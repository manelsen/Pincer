defmodule Pincer.Channels.TelegramTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  import Mox

  alias Pincer.Channels.Telegram
  alias Pincer.Channels.Telegram.APIMock

  setup do
    Application.put_env(:pincer, :telegram_api, Pincer.Channels.Telegram.APIMock)

    on_exit(fn ->
      Application.put_env(:pincer, :telegram_api, Pincer.Channels.TestAdapter)
    end)

    verify_on_exit!()
    :ok
  end

  describe "markdown_to_html/1" do
    test "converts basic bold markdown" do
      assert Telegram.markdown_to_html("**hello**") == "<b>hello</b>"
    end

    test "supports horizontal rules" do
      assert Telegram.markdown_to_html("---") == "<b>───────────────</b>"
    end
  end

  describe "send_message/2" do
    test "envia mensagem via API do Telegram" do
      chat_id = "987654"
      text = "olá telegram"

      APIMock
      |> expect(:send_message, fn ^chat_id, ^text, _opts ->
        {:ok, %{message_id: 12345}}
      end)

      assert Telegram.send_message(chat_id, text) == {:ok, 12345}
    end

    test "divide mensagens muito longas (erro 'text is too long')" do
      chat_id = "987654"
      long_text = String.duplicate("b", 5000)

      APIMock
      |> expect(:send_message, fn ^chat_id, _text, _opts ->
        {:error, %Telegex.Error{description: "Bad Request: text is too long", error_code: 400}}
      end)
      |> expect(:send_message, 2, fn ^chat_id, _chunk, _opts ->
        {:ok, %{message_id: 12345}}
      end)

      assert Telegram.send_message(chat_id, long_text) == {:ok, 12345}
    end

    test "evita recursão infinita se fallback de HTML falhar" do
      chat_id = "111"
      # Conteúdo que falha no parse HTML
      bad_html = "<b>sem fechamento"

      # 1. Tenta enviar com HTML -> Falha
      # 2. Faz o fallback e tenta texto puro -> Falha DE NOVO (ex: chat_id inexistente)
      # 3. Não deve mais tentarFallback se já estiver sem parse_mode
      APIMock
      |> expect(:send_message, fn ^chat_id, _text, opts ->
        assert opts[:parse_mode] == "HTML"

        {:error,
         %Telegex.Error{description: "Bad Request: can't parse entities", error_code: 400}}
      end)
      |> expect(:send_message, fn ^chat_id, _text, opts ->
        refute Keyword.has_key?(opts, :parse_mode)
        {:error, %Telegex.Error{description: "Bad Request: chat not found", error_code: 400}}
      end)

      assert {:error, "Bad Request: chat not found"} = Telegram.send_message(chat_id, bad_html)
    end
  end

  describe "update_message/3" do
    test "instancia edição via API do Telegram" do
      chat_id = "987654"
      mid = 12345
      text = "editado"

      APIMock
      |> expect(:edit_message_text, fn ^chat_id, ^mid, _text, _opts ->
        {:ok, %{}}
      end)

      assert Telegram.update_message(chat_id, mid, text) == :ok
    end

    test "ignora erro de 'message is not modified'" do
      APIMock
      |> expect(:edit_message_text, fn _, _, _, _ ->
        {:error,
         %Telegex.Error{description: "Bad Request: message is not modified", error_code: 400}}
      end)

      assert Telegram.update_message("1", 1, "igual") == :ok
    end
  end

  describe "poller initialization" do
    test "inicia supervisor sem bloquear em chamadas de rede" do
      assert {:ok, _} = Telegram.init(%{"token_env" => "TELEGRAM_BOT_TOKEN"})
    end
  end

  describe "polling hardening" do
    test "next_poll_interval/1 aplica backoff exponencial com teto" do
      assert Telegram.UpdatesProvider.next_poll_interval(0) == 1_000
      assert Telegram.UpdatesProvider.next_poll_interval(1) == 2_000
      assert Telegram.UpdatesProvider.next_poll_interval(2) == 4_000
      assert Telegram.UpdatesProvider.next_poll_interval(5) == 30_000
      assert Telegram.UpdatesProvider.next_poll_interval(-1) == 1_000
      assert Telegram.UpdatesProvider.next_poll_interval(:invalid) == 1_000
    end

    test "falha de polling incrementa contador de falhas sem avançar offset" do
      APIMock
      |> expect(:get_updates, fn opts ->
        assert opts[:offset] == 0
        assert opts[:timeout] == 5
        {:error, %Req.TransportError{reason: :timeout}}
      end)

      {:ok, pid} = Telegram.UpdatesProvider.start_link(nil)
      allow(APIMock, self(), pid)

      send(pid, :poll)
      Process.sleep(50)

      state = :sys.get_state(pid)
      assert state.offset == 0
      assert state.failures == 1

      GenServer.stop(pid)
    end

    test "sucesso apos falha reseta contador e avanca offset" do
      APIMock
      |> expect(:get_updates, fn opts ->
        assert opts[:offset] == 0
        {:error, %Req.TransportError{reason: :timeout}}
      end)
      |> expect(:get_updates, fn opts ->
        assert opts[:offset] == 0
        {:ok, [%{update_id: 41}]}
      end)

      {:ok, pid} = Telegram.UpdatesProvider.start_link(nil)
      allow(APIMock, self(), pid)

      send(pid, :poll)
      Process.sleep(50)
      assert :sys.get_state(pid).failures == 1
      assert :sys.get_state(pid).offset == 0

      send(pid, :poll)
      Process.sleep(50)

      state = :sys.get_state(pid)
      assert state.failures == 0
      assert state.offset == 42

      GenServer.stop(pid)
    end

    test "falha transitoria de polling usa log warning em vez de erro continuo" do
      APIMock
      |> expect(:get_updates, fn _opts ->
        {:error, %Req.TransportError{reason: :timeout}}
      end)

      {:ok, pid} = Telegram.UpdatesProvider.start_link(nil)
      allow(APIMock, self(), pid)

      log =
        capture_log(fn ->
          send(pid, :poll)
          Process.sleep(50)
        end)

      assert log =~ "Telegram polling error"
      assert log =~ "[warning]"
      refute log =~ "[error] Telegram polling error"

      GenServer.stop(pid)
    end
  end

  describe "menu ergonomics" do
    test "register_commands/0 includes /menu" do
      APIMock
      |> expect(:set_my_commands, fn commands, _opts ->
        assert Enum.any?(commands, &(&1.command == "menu"))
        {:ok, true}
      end)

      assert :ok == Telegram.register_commands()
    end

    test "menu_reply_markup/0 contains persistent Menu button" do
      markup = Telegram.menu_reply_markup()

      assert is_map(markup)
      assert markup.keyboard == [[%{text: "Menu"}]]
      assert markup.resize_keyboard == true
      assert markup.is_persistent == true
      assert markup.one_time_keyboard == false
    end

    test "plain status text routes to /status command for keyboard-first navigation" do
      APIMock
      |> expect(:get_updates, fn _opts ->
        {:ok,
         [
           %{
             update_id: 13,
             message: %{text: "status", chat: %{id: 901, type: "private"}}
           }
         ]}
      end)
      |> expect(:send_message, fn 901, text, _opts ->
        assert text =~ "Session Status"
        {:ok, %{message_id: 613}}
      end)

      {:ok, pid} = Pincer.Channels.Telegram.UpdatesProvider.start_link(nil)
      allow(APIMock, self(), pid)
      ref = Process.monitor(pid)

      send(pid, :poll)
      Process.sleep(100)

      refute_receive {:DOWN, ^ref, :process, ^pid, _}
      GenServer.stop(pid)
    end
  end

  describe "callback interactions" do
    test "models command filters provider callbacks above telegram callback limit" do
      long_provider_id = "provider_" <> String.duplicate("x", 80)

      Application.put_env(:pincer, :llm_providers, %{
        "z_ai" => %{default_model: "glm-4.7"},
        long_provider_id => %{default_model: "model-x"}
      })

      on_exit(fn ->
        Application.delete_env(:pincer, :llm_providers)
      end)

      APIMock
      |> expect(:get_updates, fn _opts ->
        {:ok,
         [
           %{
             update_id: 9,
             message: %{text: "/models", chat: %{id: 444, type: "private"}}
           }
         ]}
      end)
      |> expect(:send_message, fn 444, text, opts ->
        assert text =~ "Select AI Provider"

        callback_ids =
          opts[:reply_markup].inline_keyboard
          |> List.flatten()
          |> Enum.map(&Map.get(&1, :callback_data))

        assert "select_provider:z_ai" in callback_ids
        assert Enum.all?(callback_ids, &(byte_size(&1) <= 64))
        refute Enum.any?(callback_ids, &String.contains?(&1, long_provider_id))

        {:ok, %{message_id: 120}}
      end)

      {:ok, pid} = Pincer.Channels.Telegram.UpdatesProvider.start_link(nil)
      allow(APIMock, self(), pid)
      ref = Process.monitor(pid)

      send(pid, :poll)
      Process.sleep(100)

      refute_receive {:DOWN, ^ref, :process, ^pid, _}
      GenServer.stop(pid)
    end

    test "provider selection callback uses edit_message_text/4" do
      Application.put_env(:pincer, :llm_providers, %{
        "z_ai_coding" => %{default_model: "glm-4.7"}
      })

      APIMock
      |> expect(:get_updates, fn _opts ->
        {:ok,
         [
           %{
             update_id: 1,
             callback_query: %{
               data: "select_provider:z_ai_coding",
               message: %{chat: %{id: 924_255_495}, message_id: 1249}
             }
           }
         ]}
      end)
      |> expect(:edit_message_text, fn chat_id, message_id, text, opts ->
        assert chat_id == 924_255_495
        assert message_id == 1249
        assert text =~ "Select Model for z_ai_coding"
        assert %Telegex.Type.InlineKeyboardMarkup{} = opts[:reply_markup]
        {:ok, %{}}
      end)

      {:ok, pid} = Pincer.Channels.Telegram.UpdatesProvider.start_link(nil)
      allow(APIMock, self(), pid)
      ref = Process.monitor(pid)

      send(pid, :poll)
      Process.sleep(100)

      refute_receive {:DOWN, ^ref, :process, ^pid, _}
      GenServer.stop(pid)
    end

    test "unknown callback data does not crash provider and replies with guidance" do
      APIMock
      |> expect(:get_updates, fn _opts ->
        {:ok,
         [
           %{
             update_id: 10,
             callback_query: %{
               data: "totally_unknown_action",
               message: %{chat: %{id: 321}, message_id: 99}
             }
           }
         ]}
      end)
      |> expect(:send_message, fn chat_id, text, opts ->
        assert chat_id == 321
        assert text =~ "Opcao de menu"
        assert opts[:reply_markup][:keyboard] == [[%{text: "Menu"}]]
        {:ok, %{message_id: 100}}
      end)

      {:ok, pid} = Pincer.Channels.Telegram.UpdatesProvider.start_link(nil)
      allow(APIMock, self(), pid)
      ref = Process.monitor(pid)

      send(pid, :poll)
      Process.sleep(100)

      refute_receive {:DOWN, ^ref, :process, ^pid, _}
      GenServer.stop(pid)
    end

    test "malformed callback payload is ignored without terminating provider" do
      APIMock
      |> expect(:get_updates, fn _opts ->
        {:ok,
         [
           %{
             update_id: 11,
             callback_query: %{
               data: "select_provider:z_ai_coding"
             }
           }
         ]}
      end)

      {:ok, pid} = Pincer.Channels.Telegram.UpdatesProvider.start_link(nil)
      allow(APIMock, self(), pid)
      ref = Process.monitor(pid)

      send(pid, :poll)
      Process.sleep(100)

      refute_receive {:DOWN, ^ref, :process, ^pid, _}
      GenServer.stop(pid)
    end

    test "callback flood with malformed payloads does not crash poller" do
      malformed_updates =
        for n <- 1..60 do
          %{
            update_id: 1000 + n,
            callback_query: if(rem(n, 2) == 0, do: "broken", else: %{data: "select_model::"})
          }
        end

      final_valid_update = %{
        update_id: 2000,
        callback_query: %{
          data: "totally_unknown_action",
          message: %{chat: %{id: 777}, message_id: 404}
        }
      }

      APIMock
      |> expect(:get_updates, fn _opts ->
        {:ok, malformed_updates ++ [final_valid_update]}
      end)
      |> expect(:send_message, fn 777, text, opts ->
        assert text =~ "Opcao de menu"
        assert opts[:reply_markup][:keyboard] == [[%{text: "Menu"}]]
        {:ok, %{message_id: 909}}
      end)

      {:ok, pid} = Pincer.Channels.Telegram.UpdatesProvider.start_link(nil)
      allow(APIMock, self(), pid)
      ref = Process.monitor(pid)

      send(pid, :poll)
      Process.sleep(120)

      state = :sys.get_state(pid)
      assert state.offset == 2001
      refute_receive {:DOWN, ^ref, :process, ^pid, _}
      GenServer.stop(pid)
    end

    test "invalid select_model callback shape returns friendly fallback" do
      APIMock
      |> expect(:get_updates, fn _opts ->
        {:ok,
         [
           %{
             update_id: 111,
             callback_query: %{
               data: "select_model::",
               message: %{chat: %{id: 333, type: "private"}, message_id: 77}
             }
           }
         ]}
      end)
      |> expect(:send_message, fn chat_id, text, opts ->
        assert chat_id == 333
        assert text =~ "Opcao de menu"
        assert opts[:reply_markup][:keyboard] == [[%{text: "Menu"}]]
        {:ok, %{message_id: 500}}
      end)

      {:ok, pid} = Pincer.Channels.Telegram.UpdatesProvider.start_link(nil)
      allow(APIMock, self(), pid)
      ref = Process.monitor(pid)

      send(pid, :poll)
      Process.sleep(100)

      refute_receive {:DOWN, ^ref, :process, ^pid, _}
      GenServer.stop(pid)
    end

    test "provider callback edit failure sends fallback message and continues polling" do
      Application.put_env(:pincer, :llm_providers, %{
        "z_ai_coding" => %{default_model: "glm-4.7"}
      })

      APIMock
      |> expect(:get_updates, fn _opts ->
        {:ok,
         [
           %{
             update_id: 12,
             callback_query: %{
               data: "select_provider:z_ai_coding",
               message: %{chat: %{id: 555}, message_id: 101}
             }
           }
         ]}
      end)
      |> expect(:edit_message_text, fn 555, 101, _text, _opts ->
        {:error,
         %Telegex.Error{description: "Bad Request: message to edit not found", error_code: 400}}
      end)
      |> expect(:send_message, fn chat_id, text, opts ->
        assert chat_id == 555
        assert text =~ "Nao consegui atualizar o menu"
        assert opts[:reply_markup][:keyboard] == [[%{text: "Menu"}]]
        {:ok, %{message_id: 200}}
      end)

      {:ok, pid} = Pincer.Channels.Telegram.UpdatesProvider.start_link(nil)
      allow(APIMock, self(), pid)
      ref = Process.monitor(pid)

      send(pid, :poll)
      Process.sleep(100)

      refute_receive {:DOWN, ^ref, :process, ^pid, _}
      GenServer.stop(pid)
    end
  end

  describe "attachment input preparation" do
    test "prepare_input_content/2 converts photo updates into multimodal parts" do
      message = %{
        caption: "Analisa esta imagem",
        photo: [
          %{file_id: "photo_small", file_size: 120, file_unique_id: "img_u1"},
          %{file_id: "photo_large", file_size: 240, file_unique_id: "img_u1"}
        ]
      }

      APIMock
      |> expect(:get_file, fn "photo_large" ->
        {:ok, %{file_path: "photos/file_abc.jpg"}}
      end)

      assert {:ok, [%{"type" => "text", "text" => "Analisa esta imagem"}, ref]} =
               Telegram.UpdatesProvider.prepare_input_content(message, APIMock)

      assert ref == %{
               "type" => "attachment_ref",
               "url" => "telegram://file/photos/file_abc.jpg",
               "mime_type" => "image/jpeg",
               "filename" => "photo_img_u1.jpg",
               "size" => 240
             }
    end

    test "prepare_input_content/2 includes log documents as attachment_ref" do
      message = %{
        caption: "Leia o log",
        document: %{
          file_id: "log_file_1",
          file_name: "agent.log",
          file_size: 1024,
          mime_type: "text/plain"
        }
      }

      APIMock
      |> expect(:get_file, fn "log_file_1" ->
        {:ok, %{file_path: "documents/agent.log"}}
      end)

      assert {:ok, [%{"type" => "text", "text" => "Leia o log"}, ref]} =
               Telegram.UpdatesProvider.prepare_input_content(message, APIMock)

      assert ref == %{
               "type" => "attachment_ref",
               "url" => "telegram://file/documents/agent.log",
               "mime_type" => "text/plain",
               "filename" => "agent.log",
               "size" => 1024
             }
    end
  end

  describe "dm access policy" do
    test "blocked private DM gets friendly message and does not crash provider" do
      Application.put_env(:pincer, :telegram_channel_config, %{
        "dm_policy" => %{"mode" => "allowlist", "allow_from" => ["111"]}
      })

      on_exit(fn ->
        Application.delete_env(:pincer, :telegram_channel_config)
      end)

      APIMock
      |> expect(:get_updates, fn _opts ->
        {:ok,
         [
           %{
             update_id: 20,
             message: %{text: "hello", chat: %{id: 321, type: "private"}}
           }
         ]}
      end)
      |> expect(:send_message, fn chat_id, text, opts ->
        assert chat_id == 321
        assert text =~ "nao esta autorizado"
        assert opts[:reply_markup][:keyboard] == [[%{text: "Menu"}]]
        assert opts[:parse_mode] == "HTML"
        {:ok, %{message_id: 300}}
      end)

      {:ok, pid} = Pincer.Channels.Telegram.UpdatesProvider.start_link(nil)
      allow(APIMock, self(), pid)
      ref = Process.monitor(pid)

      send(pid, :poll)
      Process.sleep(100)

      refute_receive {:DOWN, ^ref, :process, ^pid, _}
      GenServer.stop(pid)
    end
  end

  describe "pairing command" do
    test "private /pair with unknown code returns pending guidance" do
      sender_id = System.unique_integer([:positive]) + 900_000

      APIMock
      |> expect(:get_updates, fn _opts ->
        {:ok,
         [
           %{
             update_id: 21,
             message: %{text: "/pair 000000", chat: %{id: sender_id, type: "private"}}
           }
         ]}
      end)
      |> expect(:send_message, fn chat_id, text, _opts ->
        assert chat_id == sender_id
        assert text =~ "Nenhum pairing pendente"
        {:ok, %{message_id: 301}}
      end)

      {:ok, pid} = Pincer.Channels.Telegram.UpdatesProvider.start_link(nil)
      allow(APIMock, self(), pid)
      ref = Process.monitor(pid)

      send(pid, :poll)
      Process.sleep(100)

      refute_receive {:DOWN, ^ref, :process, ^pid, _}
      GenServer.stop(pid)
    end
  end

  describe "dm session scope policy" do
    test "private /status uses main session scope when configured" do
      Application.put_env(:pincer, :telegram_channel_config, %{
        "dm_session_scope" => "main"
      })

      on_exit(fn ->
        Application.delete_env(:pincer, :telegram_channel_config)
      end)

      APIMock
      |> expect(:get_updates, fn _opts ->
        {:ok,
         [
           %{
             update_id: 31,
             message: %{text: "/status", chat: %{id: 321, type: "private"}}
           }
         ]}
      end)
      |> expect(:send_message, fn chat_id, text, _opts ->
        assert chat_id == 321
        assert text =~ "telegram_main"
        {:ok, %{message_id: 401}}
      end)

      {:ok, pid} = Pincer.Channels.Telegram.UpdatesProvider.start_link(nil)
      allow(APIMock, self(), pid)
      ref = Process.monitor(pid)

      send(pid, :poll)
      Process.sleep(100)

      refute_receive {:DOWN, ^ref, :process, ^pid, _}
      GenServer.stop(pid)
    end

    test "private select_model callback uses main session scope when configured" do
      Application.put_env(:pincer, :llm_providers, %{
        "z_ai" => %{default_model: "glm-4.7"}
      })

      Application.put_env(:pincer, :telegram_channel_config, %{
        "dm_session_scope" => "main"
      })

      on_exit(fn ->
        Application.delete_env(:pincer, :telegram_channel_config)
        Application.delete_env(:pincer, :llm_providers)
      end)

      APIMock
      |> expect(:get_updates, fn _opts ->
        {:ok,
         [
           %{
             update_id: 32,
             callback_query: %{
               data: "select_model:z_ai:glm-4.7",
               message: %{chat: %{id: 321, type: "private"}, message_id: 111}
             }
           }
         ]}
      end)
      |> expect(:edit_message_text, fn 321, 111, text, _opts ->
        assert text =~ "Session: `telegram_main`"
        {:ok, %{}}
      end)

      {:ok, pid} = Pincer.Channels.Telegram.UpdatesProvider.start_link(nil)
      allow(APIMock, self(), pid)
      ref = Process.monitor(pid)

      send(pid, :poll)
      Process.sleep(100)

      refute_receive {:DOWN, ^ref, :process, ^pid, _}
      GenServer.stop(pid)
    end
  end
end
