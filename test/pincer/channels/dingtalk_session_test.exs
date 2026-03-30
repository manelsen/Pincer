defmodule Pincer.Channels.DingTalk.SessionTest do
  use ExUnit.Case, async: false

  defmodule MockDingTalkChannel do
    @moduledoc false

    def send_message(chat_id, text) do
      send(self(), {:send_message, chat_id, text})
      {:ok, %{}}
    end
  end

  defmodule MockDingTalkAPI do
    @moduledoc false

    def create_card(content, config) do
      send(self(), {:create_card, content, config})
      {:ok, %{"cardInstanceId" => "card_mock_123"}}
    end

    def update_card(card_id, content) do
      send(self(), {:update_card, card_id, content})
      {:ok, %{}}
    end
  end

  alias Pincer.Channels.DingTalk.Session

  @staff_id "staff_test_001"
  @session_id "dingtalk_#{@staff_id}"

  setup do
    previous_channel = Application.get_env(:pincer, :dingtalk_channel_module)
    previous_api = Application.get_env(:pincer, :dingtalk_api_module)

    Application.put_env(:pincer, :dingtalk_channel_module, MockDingTalkChannel)
    Application.put_env(:pincer, :dingtalk_api_module, MockDingTalkAPI)

    on_exit(fn ->
      if previous_channel do
        Application.put_env(:pincer, :dingtalk_channel_module, previous_channel)
      else
        Application.delete_env(:pincer, :dingtalk_channel_module)
      end

      if previous_api do
        Application.put_env(:pincer, :dingtalk_api_module, previous_api)
      else
        Application.delete_env(:pincer, :dingtalk_api_module)
      end
    end)

    :ok
  end

  describe "on_agent_response/3" do
    test "sends final message to the user" do
      state = %{chat_id: @staff_id, session_id: @session_id, buffer: "", card_ref: nil}

      Session.on_agent_response("Final answer", nil, state)

      assert_receive {:send_message, @staff_id, "Final answer"}
    end

    test "does not send empty response" do
      state = %{chat_id: @staff_id, session_id: @session_id, buffer: "", card_ref: nil}

      Session.on_agent_response("", nil, state)

      refute_received {:send_message, _, _}
    end

    test "resets card_ref after response" do
      state = %{
        chat_id: @staff_id,
        session_id: @session_id,
        buffer: "partial",
        card_ref: "card_123"
      }

      new_state = Session.on_agent_response("Done", nil, state)

      assert new_state.card_ref == nil
      assert new_state.buffer == ""
    end
  end

  describe "on_agent_partial/2" do
    test "creates card on first token when card_ref is nil" do
      state = %{chat_id: @staff_id, session_id: @session_id, buffer: "", card_ref: nil}

      new_state = Session.on_agent_partial("Hello", state)

      assert new_state.card_ref == "card_mock_123"
      assert_receive {:create_card, %{"content" => "Hello"}, %{"cardTemplateId" => "streaming"}}
    end

    test "updates existing card on subsequent tokens" do
      state = %{
        chat_id: @staff_id,
        session_id: @session_id,
        buffer: "Hello",
        card_ref: "card_456"
      }

      new_state = Session.on_agent_partial(" world", state)

      assert new_state.buffer == "Hello world"
      assert_receive {:update_card, "card_456", %{"content" => "Hello world"}}
    end
  end

  describe "on_agent_error/2" do
    test "sends error text to the user" do
      state = %{chat_id: @staff_id, session_id: @session_id, buffer: "", card_ref: nil}

      new_state = Session.on_agent_error("Something went wrong", state)

      assert_receive {:send_message, @staff_id, "[Error] Something went wrong"}
      assert new_state.card_ref == nil
      assert new_state.buffer == ""
    end
  end
end
