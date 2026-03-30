defmodule Pincer.Channels.Line.SessionTest do
  use ExUnit.Case, async: false

  defmodule MockAPI do
    @moduledoc false

    def push_message(to, messages) do
      send(self(), {:push_message, to, messages})
      {:ok, %{}}
    end
  end

  alias Pincer.Channels.Line.Session

  @user_id "U9876543210"
  @session_id "line_#{@user_id}"

  setup do
    previous = Application.get_env(:pincer, :line_api_module)
    Application.put_env(:pincer, :line_api_module, MockAPI)

    on_exit(fn ->
      if previous do
        Application.put_env(:pincer, :line_api_module, previous)
      else
        Application.delete_env(:pincer, :line_api_module)
      end
    end)

    :ok
  end

  describe "on_agent_response/3" do
    test "sends final message via push_message" do
      state = %{chat_id: @user_id, session_id: @session_id, buffer: ""}

      Session.on_agent_response("Final answer", nil, state)

      assert_receive {:push_message, @user_id, [%{"type" => "text", "text" => "Final answer"}]}
    end

    test "flushes pending buffer before sending final message" do
      state = %{chat_id: @user_id, session_id: @session_id, buffer: "Pending chunk. "}

      Session.on_agent_response("Final answer", nil, state)

      # Buffer flushed first
      assert_receive {:push_message, @user_id, [%{"type" => "text", "text" => "Pending chunk. "}]}
      # Then final message
      assert_receive {:push_message, @user_id, [%{"type" => "text", "text" => "Final answer"}]}
    end
  end

  describe "on_agent_partial/2" do
    test "accumulates buffer without flushing when no boundary reached" do
      state = %{chat_id: @user_id, session_id: @session_id, buffer: ""}

      state1 = Session.on_agent_partial("Hello ", state)
      assert state1.buffer == "Hello "
      refute_received {:push_message, _, _}
    end

    test "flushes on sentence boundary" do
      state = %{chat_id: @user_id, session_id: @session_id, buffer: "Hello "}

      state1 = Session.on_agent_partial("world. ", state)
      assert state1.buffer == ""

      assert_receive {:push_message, @user_id, [%{"type" => "text", "text" => "Hello world. "}]}
    end

    test "flushes when buffer exceeds chunk size threshold" do
      long_chunk = String.duplicate("a", 501)
      state = %{chat_id: @user_id, session_id: @session_id, buffer: ""}

      state1 = Session.on_agent_partial(long_chunk, state)
      assert state1.buffer == ""

      assert_receive {:push_message, @user_id, [%{"type" => "text", "text" => ^long_chunk}]}
    end
  end

  describe "on_agent_error/2" do
    test "sends error text to user via push_message" do
      state = %{chat_id: @user_id, session_id: @session_id, buffer: "some buffered text"}

      new_state = Session.on_agent_error("Something went wrong", state)

      # Buffer flushed first
      assert_receive {:push_message, @user_id,
                      [%{"type" => "text", "text" => "some buffered text"}]}

      # Error message sent
      assert_receive {:push_message, @user_id,
                      [%{"type" => "text", "text" => "[Error] Something went wrong"}]}

      assert new_state.buffer == ""
    end
  end
end
