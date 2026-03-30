defmodule Pincer.Channels.Feishu.SessionTest do
  use ExUnit.Case, async: false

  alias Pincer.Channels.Feishu.Session

  # Mock API module that records calls for assertions.
  defmodule MockAPI do
    use Agent

    def start_link(_opts \\ []) do
      Agent.start_link(fn -> [] end, name: __MODULE__)
    end

    def calls do
      Agent.get(__MODULE__, & &1)
    end

    def reset do
      Agent.update(__MODULE__, fn _ -> [] end)
    end

    def track(call) do
      Agent.update(__MODULE__, fn calls -> calls ++ [call] end)
    end

    def send_message(receive_id, content, msg_type) do
      track({:send_message, receive_id, content, msg_type})
      {:ok, %{"message_id" => "mock_card_123"}}
    end

    def update_card(card_token, new_content) do
      track({:update_card, card_token, new_content})
      {:ok, %{}}
    end
  end

  # Mock that always fails send_message (for error-path testing).
  defmodule ErrorMockAPI do
    def send_message(_receive_id, _content, _msg_type) do
      {:error, :timeout}
    end

    def update_card(_card_token, _new_content) do
      {:ok, %{}}
    end
  end

  setup do
    start_supervised!(MockAPI)

    original = Application.get_env(:pincer, :feishu_api_module)
    Application.put_env(:pincer, :feishu_api_module, MockAPI)

    on_exit(fn ->
      if original do
        Application.put_env(:pincer, :feishu_api_module, original)
      else
        Application.delete_env(:pincer, :feishu_api_module)
      end
    end)

    MockAPI.reset()

    state = %{
      chat_id: "test_chat_001",
      session_id: "feishu_test_open_id",
      buffer: "",
      card_ref: nil
    }

    {:ok, state: state}
  end

  describe "on_agent_partial/2" do
    test "first call creates a card via send_message with interactive type", %{state: state} do
      new_state = Session.on_agent_partial("Hello", state)

      calls = MockAPI.calls()
      assert length(calls) == 1

      {:send_message, receive_id, content, msg_type} = hd(calls)
      assert receive_id == "test_chat_001"
      assert msg_type == "interactive"

      # Content should be a valid JSON card payload
      {:ok, card} = Jason.decode(content)

      assert %{
               "elements" => [
                 %{"tag" => "div", "text" => %{"tag" => "lark_md", "content" => "Hello"}}
               ]
             } = card

      # State tracks the card ref and buffers the text
      assert new_state.card_ref == "mock_card_123"
      assert new_state.buffer == "Hello"
    end

    test "subsequent calls update the existing card in-place", %{state: state} do
      # First partial creates the card
      state1 = Session.on_agent_partial("Hello", state)
      MockAPI.reset()

      # Second partial updates the card
      state2 = Session.on_agent_partial(" World", state1)

      calls = MockAPI.calls()
      assert length(calls) == 1

      {:update_card, card_token, updated_card} = hd(calls)
      assert card_token == "mock_card_123"

      # Card content reflects accumulated buffer
      assert %{"elements" => [%{"text" => %{"content" => "Hello World"}}]} = updated_card

      # Buffer accumulates
      assert state2.buffer == "Hello World"
      assert state2.card_ref == "mock_card_123"
    end

    test "falls back to buffer accumulation when card creation fails", %{state: state} do
      # Use the error mock for this test only
      error_mock = Pincer.Channels.Feishu.SessionTest.ErrorMockAPI
      Application.put_env(:pincer, :feishu_api_module, error_mock)

      new_state = Session.on_agent_partial("Hello", state)

      # Card ref stays nil, buffer accumulates as fallback
      assert new_state.card_ref == nil
      assert new_state.buffer == "Hello"

      # Restore original mock
      Application.put_env(:pincer, :feishu_api_module, MockAPI)
    end
  end

  describe "on_agent_response/3" do
    test "sends final message via send_message as text type", %{state: state} do
      new_state = Session.on_agent_response("Final answer", nil, state)

      calls = MockAPI.calls()
      assert length(calls) == 1

      {:send_message, receive_id, content, msg_type} = hd(calls)
      assert receive_id == "test_chat_001"
      assert msg_type == "text"

      {:ok, decoded} = Jason.decode(content)
      assert decoded["text"] == "Final answer"

      # State is reset
      assert new_state.buffer == ""
      assert new_state.card_ref == nil
    end

    test "does not send when response is empty", %{state: state} do
      new_state = Session.on_agent_response("", nil, state)

      calls = MockAPI.calls()
      assert calls == []

      assert new_state.buffer == ""
      assert new_state.card_ref == nil
    end
  end

  describe "on_agent_error/2" do
    test "sends error text via send_message", %{state: state} do
      new_state = Session.on_agent_error("Something went wrong", state)

      calls = MockAPI.calls()
      assert length(calls) == 1

      {:send_message, receive_id, content, msg_type} = hd(calls)
      assert receive_id == "test_chat_001"
      assert msg_type == "text"

      {:ok, decoded} = Jason.decode(content)
      assert decoded["text"] == "[Error] Something went wrong"

      assert new_state.buffer == ""
      assert new_state.card_ref == nil
    end
  end
end
