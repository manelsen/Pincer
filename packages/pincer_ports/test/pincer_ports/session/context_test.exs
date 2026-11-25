defmodule PincerPorts.Session.ContextTest do
  use ExUnit.Case, async: true

  alias PincerPorts.Session.Context

  test "uses the supplied workspace path in a new context and its start options" do
    context =
      Context.new(
        session_id: "telegram_123",
        root_agent_id: "root_agent",
        workspace_path: "custom/workspace"
      )

    assert %Context{
             workspace_path: "custom/workspace",
             root_agent_source: :session_scope,
             blackboard_scope: "root_agent"
           } = context

    assert Context.to_start_opts(context)[:workspace_path] == "custom/workspace"
  end

  test "requires the caller to supply workspace_path" do
    assert_raise KeyError, ~r/workspace_path/, fn ->
      Context.new(session_id: "telegram_123", root_agent_id: "root_agent")
    end
  end
end
