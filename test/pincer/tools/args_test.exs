defmodule Pincer.Adapters.Tools.ArgsTest do
  use ExUnit.Case, async: true

  alias Pincer.Adapters.Tools.Args

  test "string modes distinguish absent values, empty values and whitespace" do
    assert Args.string(nil, :trimmed) == {:error, :missing}
    assert Args.string(1, :trimmed) == {:error, :invalid}
    assert Args.string("  ", :trimmed) == {:error, :empty}
    assert Args.string(" a ", :trimmed) == {:ok, "a"}
    assert Args.string(" a ", :nonblank) == {:ok, " a "}
    assert Args.string("  ", :nonempty) == {:ok, "  "}
    assert Args.string("", :raw) == {:ok, ""}
  end

  test "workspace lookup prefers the string key and invokes the fallback when absent" do
    assert Args.workspace_root(%{"workspace_path" => "string", workspace_path: "atom"}, fn ->
             flunk("unexpected fallback")
           end) == "string"

    assert Args.workspace_root(%{workspace_path: "/configured"}) == "/configured"
    assert Args.workspace_root(%{}, fn -> "/default" end) == "/default"
  end

  test "argument lookup keeps false and context reads fall back to the atom key" do
    assert Args.get(%{"recursive" => false, recursive: true}, "recursive") == false
    assert Args.get(%{recursive: true}, "recursive") == true
    assert Args.session_id(%{"session_id" => false, session_id: "s"}) == "s"
  end
end
