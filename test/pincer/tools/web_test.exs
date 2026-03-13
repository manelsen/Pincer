defmodule Pincer.Adapters.Tools.WebTest do
  use ExUnit.Case, async: true

  alias Pincer.Adapters.Tools.Web

  test "spec exposes split web_search and web_fetch tools" do
    specs = Web.spec()

    assert is_list(specs)

    names =
      Enum.map(specs, fn spec ->
        spec[:name] || spec["name"]
      end)

    assert "web_search" in names
    assert "web_fetch" in names
    refute "web" in names
  end

  test "dispatches search via tool_name without legacy action field" do
    assert {:error, msg} = Web.execute(%{"tool_name" => "web_search"})
    assert msg =~ "query"
  end

  test "dispatches fetch via tool_name without legacy action field" do
    assert {:error, msg} =
             Web.execute(%{"tool_name" => "web_fetch", "url" => "http://localhost/admin"})

    assert msg =~ "internal hosts" or msg =~ "not allowed"
  end
end
