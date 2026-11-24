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

  describe "markdown_to_html/1" do
    test "parses structural Markdown through EarmarkParser" do
      assert Telegram.markdown_to_html("**bold** and [link](https://example.com)") ==
               "<b>bold</b> and <a href=\"https://example.com\">link</a>"
    end

    test "escapes link attributes end to end" do
      assert Telegram.markdown_to_html("[link](https://example.com/?a=1&b=2)") ==
               "<a href=\"https://example.com/?a=1&amp;b=2\">link</a>"
    end

    test "escapes AST link attributes" do
      ast = [{"a", [{"href", "https://example.com/?q=\"quoted\""}], ["link"], %{}}]

      assert Pincer.Channels.Telegram.Renderer.render(ast) ==
               "<a href=\"https://example.com/?q=&quot;quoted&quot;\">link</a>"
    end

    test "sanitizes code block language attributes" do
      ast = [
        {"pre", [], [{"code", [{"class", "language-\"><script>"}], ["code"], %{}}], %{}}
      ]

      assert Pincer.Channels.Telegram.Renderer.render(ast) ==
               "<pre><code class=\"language-script\">code</code></pre>"
    end
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

    test "formats <thinking> as preformatted block when skip_reasoning_strip is enabled" do
      chat_id = 101

      APIMock
      |> expect(:send_message, fn ^chat_id, text, opts ->
        assert text =~ "💭 Reasoning"
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
