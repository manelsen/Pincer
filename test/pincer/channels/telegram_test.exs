defmodule Pincer.Channels.TelegramTest do
  use ExUnit.Case, async: false
  import Mox

  alias Pincer.Channels.Telegram
  alias Pincer.Channels.Telegram.APIMock

  setup do
    Application.put_env(:pincer, :telegram_api, APIMock)

    on_exit(fn ->
      Application.put_env(:pincer, :telegram_api, Pincer.Channels.TestAdapter)
    end)

    verify_on_exit!()
    :ok
  end

  describe "send_message/3" do
    test "removes <thinking> without skip_reasoning_strip" do
      chat_id = 100

      APIMock
      |> expect(:send_message, fn ^chat_id, text, opts ->
        assert text == "Resposta final"
        assert opts[:parse_mode] == "HTML"
        {:ok, %{message_id: 1}}
      end)

      assert {:ok, 1} =
               Telegram.send_message(
                 chat_id,
                 "<thinking>segredo</thinking>\n\nResposta final"
               )
    end

    test "formats <thinking> when skip_reasoning_strip is enabled" do
      chat_id = 101

      APIMock
      |> expect(:send_message, fn ^chat_id, text, opts ->
        assert text =~ "<blockquote><b>💭 Reasoning</b>"
        assert text =~ "segredo"
        assert text =~ "Resposta final"
        assert opts[:parse_mode] == "HTML"
        {:ok, %{message_id: 2}}
      end)

      assert {:ok, 2} =
               Telegram.send_message(
                 chat_id,
                 "<thinking>segredo</thinking>\n\nResposta final",
                 skip_reasoning_strip: true
               )
    end
  end
end
