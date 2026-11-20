defmodule Pincer.Core.Executor.LoopGuardTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.Executor.LoopGuard

  describe "check/3" do
    test "returns :ok when within depth limit and no loop detected" do
      history = [
        assistant_with_calls([call("file_system", ~s({"path":"a.ex"}))]),
        assistant_with_calls([call("file_system", ~s({"path":"b.ex"}))])
      ]

      assert :ok = LoopGuard.check(history, 2, 10)
    end

    test "returns {:error, {:depth_exceeded, depth}} when depth exceeds max_depth" do
      assert {:error, {:depth_exceeded, 6}} = LoopGuard.check([], 6, 5)
    end

    test "detects 3 consecutive identical tool-call fingerprints" do
      msg = assistant_with_calls([call("safe_shell", ~s({"command":"ls"}))])
      history = [msg, msg, msg]

      assert {:error, :tool_loop} = LoopGuard.check(history, 3, 10)
    end

    test "does not flag 2 identical tool calls as a loop" do
      msg = assistant_with_calls([call("safe_shell", ~s({"command":"ls"}))])
      assert :ok = LoopGuard.check([msg, msg], 2, 10)
    end

    test "detects same tool+args pair appearing 10+ times in last 15 messages" do
      repeated = assistant_with_calls([call("file_system", ~s({"path":"same.txt"}))])
      varied = assistant_with_calls([call("web_fetch", ~s({"url":"https://example.com"}))])

      history = List.duplicate(repeated, 5) ++ [varied] ++ List.duplicate(repeated, 5)
      assert {:error, :tool_loop} = LoopGuard.check(history, 11, 20)
    end

    test "does not flag high frequency when arguments differ" do
      history =
        Enum.map(1..12, fn idx ->
          assistant_with_calls([call("file_system", ~s({"path":"file_#{idx}.txt"}))])
        end)

      assert :ok = LoopGuard.check(history, 12, 20)
    end
  end

  defp assistant_with_calls(calls) do
    %{"role" => "assistant", "content" => nil, "tool_calls" => calls}
  end

  defp call(name, arguments) do
    %{"id" => "call_#{name}", "function" => %{"name" => name, "arguments" => arguments}}
  end
end
