defmodule Pincer.Core.Session.PrunerTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.Session.Pruner

  describe "prune/2" do
    test "replaces old tool results with summary" do
      history = [
        %{"role" => "system", "content" => "system prompt"},
        %{"role" => "user", "content" => "read the file"},
        %{"role" => "tool", "content" => String.duplicate("line of code\n", 100)},
        %{"role" => "assistant", "content" => "I read the file"},
        %{"role" => "user", "content" => "what else?"},
        %{"role" => "assistant", "content" => "nothing else"}
      ]

      result = Pruner.prune(history, keep_recent: 2)

      tool_msg = Enum.at(result, 2)
      assert tool_msg["role"] == "tool"
      assert tool_msg["content"] =~ "[tool output:"
      assert tool_msg["content"] =~ "omitted]"
    end

    test "keeps recent tool results intact" do
      long_content = String.duplicate("data\n", 50)

      history = [
        %{"role" => "system", "content" => "system"},
        %{"role" => "user", "content" => "do stuff"},
        %{"role" => "tool", "content" => long_content},
        %{"role" => "assistant", "content" => "done"}
      ]

      result = Pruner.prune(history, keep_recent: 4)

      tool_msg = Enum.at(result, 2)
      assert tool_msg["content"] == long_content
    end

    test "never prunes non-tool messages" do
      history = [
        %{"role" => "system", "content" => "system"},
        %{"role" => "user", "content" => "hello"},
        %{"role" => "assistant", "content" => "hi"},
        %{"role" => "user", "content" => "bye"},
        %{"role" => "assistant", "content" => "see you"}
      ]

      result = Pruner.prune(history, keep_recent: 0)
      assert length(result) == length(history)

      Enum.each(result, fn msg ->
        assert msg["role"] in ["system", "user", "assistant"]
      end)
    end

    test "passes through empty tool results" do
      history = [
        %{"role" => "system", "content" => "system"},
        %{"role" => "tool", "content" => ""},
        %{"role" => "tool", "content" => nil}
      ]

      result = Pruner.prune(history, keep_recent: 0)

      assert Enum.at(result, 1)["content"] == ""
      assert Enum.at(result, 2)["content"] == nil
    end

    test "system message is never modified" do
      history = [
        %{"role" => "system", "content" => "important system prompt"}
      ]

      result = Pruner.prune(history, keep_recent: 0)
      assert hd(result)["content"] == "important system prompt"
    end

    test "multiple old tool results are all summarized" do
      history = [
        %{"role" => "system", "content" => "system"},
        %{"role" => "tool", "content" => "result 1"},
        %{"role" => "tool", "content" => "result 2"},
        %{"role" => "tool", "content" => "result 3"},
        %{"role" => "user", "content" => "latest"}
      ]

      result = Pruner.prune(history, keep_recent: 1)

      # First 3 tool results should be summarized
      assert Enum.at(result, 1)["content"] =~ "omitted]"
      assert Enum.at(result, 2)["content"] =~ "omitted]"
      assert Enum.at(result, 3)["content"] =~ "omitted]"
      # User message kept
      assert Enum.at(result, 4)["content"] == "latest"
    end
  end
end
