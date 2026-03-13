defmodule Pincer.Core.ProjectFlowDeliveryTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.ProjectFlowDelivery

  defmodule RouterNext do
    def on_agent_response(_session_id),
      do: {:next, %{status_message: "Task started", prompt: "continue"}}

    def on_agent_error(_session_id), do: :noop
  end

  defmodule RouterCompleted do
    def on_agent_response(_session_id), do: {:completed, %{status_message: "Task completed"}}
    def on_agent_error(_session_id), do: :noop
  end

  defmodule RouterRetry do
    def on_agent_response(_session_id), do: :noop

    def on_agent_error(_session_id),
      do: {:retry, %{status_message: "Task retrying", prompt: "retry"}}
  end

  defmodule RouterPaused do
    def on_agent_response(_session_id), do: :noop
    def on_agent_error(_session_id), do: {:paused, %{status_message: "Task paused"}}
  end

  defmodule ServerStub do
    def process_input(session_id, prompt) do
      send(self(), {:process_input, session_id, prompt})
      :ok
    end
  end

  test "on_response sends project progress and replays prompt on next" do
    ProjectFlowDelivery.on_response("s1",
      router: RouterNext,
      session_server: ServerStub,
      send_message: fn text -> send(self(), {:send_message, text}) end
    )

    assert_receive {:send_message, "Project Runner: Task started"}
    assert_receive {:process_input, "s1", "continue"}
  end

  test "on_response sends progress without replay on completed" do
    ProjectFlowDelivery.on_response("s1",
      router: RouterCompleted,
      session_server: ServerStub,
      send_message: fn text -> send(self(), {:send_message, text}) end
    )

    assert_receive {:send_message, "Project Runner: Task completed"}
    refute_receive {:process_input, _, _}
  end

  test "on_error sends project progress and replays prompt on retry" do
    ProjectFlowDelivery.on_error("s1",
      router: RouterRetry,
      session_server: ServerStub,
      send_message: fn text -> send(self(), {:send_message, text}) end
    )

    assert_receive {:send_message, "Project Runner: Task retrying"}
    assert_receive {:process_input, "s1", "retry"}
  end

  test "on_error sends progress without replay on paused" do
    ProjectFlowDelivery.on_error("s1",
      router: RouterPaused,
      session_server: ServerStub,
      send_message: fn text -> send(self(), {:send_message, text}) end
    )

    assert_receive {:send_message, "Project Runner: Task paused"}
    refute_receive {:process_input, _, _}
  end
end
