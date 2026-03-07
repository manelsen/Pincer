defmodule Pincer.Channels.SlackTest do
  use ExUnit.Case, async: true
  import Mox

  alias Pincer.Channels.Slack
  alias Pincer.Channels.Slack.APIMock

  setup do
    Application.put_env(:pincer, :slack_api, Pincer.Channels.Slack.APIMock)

    on_exit(fn ->
      Application.put_env(:pincer, :slack_api, Pincer.Channels.TestAdapter)
    end)

    verify_on_exit!()
    :ok
  end

  describe "markdown_to_mrkdwn/1" do
    test "converte negrito de Markdown para Slack asterisk" do
      # Em slack.ex temos: String.replace(~r/\*\*(.*?)\*\*/, "*\\1*")
      assert Slack.markdown_to_mrkdwn("**bold**") == "*bold*"
    end

    test "converte links para formato Slack" do
      assert Slack.markdown_to_mrkdwn("[Pincer](https://pincer.ai)") ==
               "<https://pincer.ai|Pincer>"
    end
  end

  describe "send_message/2" do
    test "envia mensagem via API do Slack" do
      channel_id = "C12345"
      text = "**olá slack**"
      token = "fake_token"

      System.put_env("SLACK_BOT_TOKEN", token)

      APIMock
      |> expect(:post, fn "chat.postMessage", ^token, payload ->
        assert payload.channel == channel_id
        assert payload.text == "*olá slack*"
        {:ok, %{ts: "1234567890.123456"}}
      end)

      assert Slack.send_message(channel_id, text) == {:ok, "1234567890.123456"}
    end
  end

  describe "update_message/3" do
    test "instancia edição via API do Slack" do
      channel_id = "C12345"
      mid = "1234567890.123456"
      text = "editado"
      token = "fake_token"

      System.put_env("SLACK_BOT_TOKEN", token)

      APIMock
      |> expect(:post, fn "chat.update", ^token, payload ->
        assert payload.channel == channel_id
        assert payload.ts == mid
        assert payload.text == text
        {:ok, %{}}
      end)

      assert Slack.update_message(channel_id, mid, text) == :ok
    end
  end

  describe "event handling" do
    test "ignora mensagens de bots" do
      # Este teste exigiria testar o SocketHandler, que é mais complexo devido ao 'use'.
      # Mas podemos testar a lógica de roteamento no Handler se o movermos para uma função testável.
    end
  end
end
