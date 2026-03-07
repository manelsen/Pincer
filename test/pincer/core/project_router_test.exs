defmodule Pincer.Core.ProjectRouterTest do
  use ExUnit.Case, async: true
  alias Pincer.Core.ProjectRouter

  describe "parse/1" do
    test "correctly parses /project start" do
      assert {:ok, :start, "Build a bot"} = ProjectRouter.parse("/project start Build a bot")
    end

    test "correctly parses /project approve" do
      assert {:ok, :approve, "p-123"} = ProjectRouter.parse("/project approve p-123")
    end

    test "correctly parses /project pause" do
      assert {:ok, :pause, "p-123"} = ProjectRouter.parse("/project pause p-123")
    end

    test "correctly parses /project modify" do
      assert {:ok, :modify, {"p-123", "Task 1\nTask 2"}} =
               ProjectRouter.parse("/project modify p-123 Task 1\nTask 2")
    end

    test "returns error for unknown command" do
      assert :error = ProjectRouter.parse("/project destroy everything")
    end
  end
end
