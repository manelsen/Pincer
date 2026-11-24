defmodule Pincer.Core.ProjectRouterTest do
  use ExUnit.Case, async: true
  alias Pincer.Core.Project.Store
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

    test "correctly parses project list and status" do
      assert {:ok, :list, nil} = ProjectRouter.parse("/project list")
      assert {:ok, :project_status, "p-123"} = ProjectRouter.parse("/project status p-123")
    end

    test "returns error for unknown command" do
      assert :error = ProjectRouter.parse("/project destroy everything")
    end
  end

  describe "project/2 channel commands" do
    test "renders durable project list as a string" do
      session_id = "router_list_#{System.unique_integer([:positive])}"
      id = "p-router-#{System.unique_integer([:positive])}"

      assert :ok =
               Store.save(%{
                 id: id,
                 session_id: session_id,
                 kind: "server",
                 status: :paused,
                 payload: %{objective: "Router test project"}
               })

      on_exit(fn -> Store.delete(id) end)

      response = ProjectRouter.project(session_id, "list")
      assert is_binary(response)
      assert response =~ id
      assert response =~ "paused"
      assert response =~ "Router test project"
    end
  end
end
