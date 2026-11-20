defmodule Pincer.Core.Executor.ToolCallTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.Executor.ToolCall

  describe "clean_specs/1" do
    test "strips internal underscore-prefixed keys recursively" do
      specs = [
        %{
          "name" => "safe_shell",
          "_internal" => true,
          "parameters" => %{
            "_meta" => "hide",
            "properties" => [%{"_hint" => 1, "type" => "string"}]
          }
        }
      ]

      assert ToolCall.clean_specs(specs) == [
               %{
                 "name" => "safe_shell",
                 "parameters" => %{"properties" => [%{"type" => "string"}]}
               }
             ]
    end
  end

  describe "normalize/1 and ensure_type/1" do
    test "normalizes string-keyed, atom-keyed, and partial tool calls" do
      assert {"c1", "safe_shell", "{}"} =
               ToolCall.normalize(%{
                 "id" => "c1",
                 "function" => %{"name" => "safe_shell", "arguments" => "{}"}
               })

      assert {"c2", "web", %{"q" => "x"}} =
               ToolCall.normalize(%{id: "c2", function: %{name: "web", arguments: %{"q" => "x"}}})

      assert {"call_unknown", "unknown", "{}"} = ToolCall.normalize(%{})

      assert %{"type" => "function", "id" => "c1"} = ToolCall.ensure_type(%{"id" => "c1"})
    end
  end

  describe "parse_arguments/1" do
    test "decodes valid JSON and passes maps through" do
      assert %{"a" => 1} = ToolCall.parse_arguments(~s({"a":1}))
      assert %{"a" => 1} = ToolCall.parse_arguments(%{"a" => 1})
      assert %{} = ToolCall.parse_arguments(:unexpected)
    end

    test "salvages truncated JSON objects with escapes, numbers, booleans, and null" do
      malformed =
        ~s({"path":"notes/a.txt","content":"line 1\\n\\"ok\\"","ok":true,"n":42,"x":null)

      assert %{
               "path" => "notes/a.txt",
               "content" => "line 1\n\"ok\"",
               "ok" => true,
               "n" => 42,
               "x" => nil
             } = ToolCall.parse_arguments(malformed)
    end

    test "returns empty map when malformed JSON cannot be salvaged" do
      assert %{} = ToolCall.parse_arguments(~s({"broken"))
      assert %{} = ToolCall.parse_arguments("not json")
    end
  end

  describe "describe/1 and names_summary/1" do
    test "formats readable descriptions and summaries" do
      calls = [
        %{"function" => %{"name" => "run_command", "arguments" => ~s({"command":"mix test"})}},
        %{
          "function" => %{
            "name" => "file_system",
            "arguments" => ~s({"action":"read","path":"README.md"})
          }
        },
        %{"function" => %{"name" => "custom_tool", "arguments" => ~s({"q":"elixir"})}}
      ]

      assert ToolCall.describe(Enum.at(calls, 0)) == "run_command: mix test"
      assert ToolCall.describe(Enum.at(calls, 1)) == "file_system read: README.md"
      assert ToolCall.describe(Enum.at(calls, 2)) == "custom_tool: elixir"
      assert ToolCall.names_summary(calls) == "run_command, file_system, custom_tool"
      assert ToolCall.names_summary([%{}]) == "unknown_tool"
    end
  end
end
