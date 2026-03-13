defmodule Pincer.Core.StatusMessagePolicyTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.StatusMessagePolicy

  describe "next_action/2" do
    test "requests send when no status message exists yet" do
      assert StatusMessagePolicy.next_action(StatusMessagePolicy.initial_state(), "running") ==
               {:send, "running"}
    end

    test "requests edit when text changes for an existing status message" do
      state = %{status_message_id: 91, status_message_text: "running"}

      assert StatusMessagePolicy.next_action(state, "finished") ==
               {:edit, 91, "finished"}
    end

    test "returns noop for blank or repeated text" do
      state = %{status_message_id: 91, status_message_text: "running"}

      assert StatusMessagePolicy.next_action(state, nil) == :noop
      assert StatusMessagePolicy.next_action(state, "   ") == :noop
      assert StatusMessagePolicy.next_action(state, "running") == :noop
    end
  end

  describe "mark_sent/3 and mark_edited/2" do
    test "stores sent message id and text" do
      state = StatusMessagePolicy.mark_sent(%{channel_id: "x"}, 123, "running")

      assert state == %{
               channel_id: "x",
               status_message_id: 123,
               status_message_text: "running"
             }
    end

    test "updates only text when edit succeeds" do
      state =
        %{status_message_id: 123, status_message_text: "running", channel_id: "x"}
        |> StatusMessagePolicy.mark_edited("finished")

      assert state == %{
               channel_id: "x",
               status_message_id: 123,
               status_message_text: "finished"
             }
    end
  end
end
