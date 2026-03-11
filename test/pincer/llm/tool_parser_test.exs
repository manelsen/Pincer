defmodule Pincer.LLM.ToolParserTest do
  use ExUnit.Case, async: true

  alias Pincer.LLM.ToolParser

  describe "parse/1" do
    test "leaves pure JSON native tool_calls untouched and content unaltered" do
      msg = %{
        "role" => "assistant",
        "content" => "Here is my reasoning.",
        "tool_calls" => [
          %{
            "id" => "call_123",
            "type" => "function",
            "function" => %{"name" => "run_command", "arguments" => "{\"command\": \"ls\"}"}
          }
        ]
      }

      assert parsed = ToolParser.parse(msg)
      assert parsed["content"] == "Here is my reasoning."
      assert length(parsed["tool_calls"]) == 1
      assert hd(parsed["tool_calls"])["id"] == "call_123"
    end

    test "extracts inline <minimax:tool_call> and cleans the content" do
      msg = %{
        "role" => "assistant",
        "content" => """
        OK, I need to create the identity file now.

        <minimax:tool_call>
          <parameter name="path">/workspace/.pincer/IDENTITY.md</parameter>
          <parameter name="content"># Clara</parameter>
        </minimax:tool_call>

        Done!
        """
      }

      assert parsed = ToolParser.parse(msg)
      assert parsed["content"] == "OK, I need to create the identity file now.\n\n\n\nDone!"

      assert [call] = parsed["tool_calls"]
      assert call["type"] == "function"
      assert Map.has_key?(call, "id")
      assert call["function"]["name"] == "file_system"

      args = Jason.decode!(call["function"]["arguments"])
      assert args["path"] == "/workspace/.pincer/IDENTITY.md"
      assert args["content"] == "# Clara"
    end

    test "extracts generic <tool_call> and infers command tool" do
      msg = %{
        "role" => "assistant",
        "content" => """
        Running migrations.
        <tool_call>
        <parameter name="command">mix ecto.migrate</parameter>
        </tool_call>
        """
      }

      assert parsed = ToolParser.parse(msg)
      assert parsed["content"] == "Running migrations."

      assert [call] = parsed["tool_calls"]
      assert call["function"]["name"] == "safe_shell"

      args = Jason.decode!(call["function"]["arguments"])
      assert args["command"] == "mix ecto.migrate"
    end

    test "merges native JSON tool_calls with hallucinated XML calls" do
      msg = %{
        "role" => "assistant",
        "content" => "<tool_call><parameter name=\"path\">foo</parameter></tool_call>",
        "tool_calls" => [
          %{
            "id" => "native_1",
            "type" => "function",
            "function" => %{"name" => "say_hi"}
          }
        ]
      }

      assert parsed = ToolParser.parse(msg)
      assert is_nil(parsed["content"])
      assert length(parsed["tool_calls"]) == 2

      [native, xml] = parsed["tool_calls"]
      assert native["id"] == "native_1"
      assert xml["function"]["name"] == "file_system"
    end

    test "normalizes anchored edit payloads into file_system anchored_edit calls" do
      msg = %{
        "role" => "assistant",
        "content" => """
        <tool_call>
        <parameter name="path">lib/pipeline.ex</parameter>
        <parameter name="anchor">12#VK</parameter>
        <parameter name="content">  :error</parameter>
        </tool_call>
        """
      }

      assert parsed = ToolParser.parse(msg)
      assert is_nil(parsed["content"])

      [call] = parsed["tool_calls"]
      assert call["function"]["name"] == "file_system"

      args = Jason.decode!(call["function"]["arguments"])
      assert args["path"] == "lib/pipeline.ex"
      assert args["action"] == "anchored_edit"
      assert args["edits"] == [%{"op" => "replace", "anchor" => "12#VK", "content" => "  :error"}]
    end
  end
end
