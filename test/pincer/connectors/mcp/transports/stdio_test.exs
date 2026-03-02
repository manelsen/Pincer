defmodule Pincer.Adapters.Connectors.MCP.Transports.StdioTest do
  use ExUnit.Case, async: true
  alias Pincer.Adapters.Connectors.MCP.Transports.Stdio

  describe "handle_data/2" do
    test "extracts single json message" do
      input = "{\"jsonrpc\": \"2.0\"}\n"
      {msgs, buffer} = Stdio.handle_data("", input)

      assert length(msgs) == 1
      assert hd(msgs)["jsonrpc"] == "2.0"
      assert buffer == ""
    end

    test "handles fragmented messages" do
      part1 = "{\"jsonrpc\": "
      part2 = "\"2.0\"}\n"

      {msgs1, buffer1} = Stdio.handle_data("", part1)
      assert msgs1 == []
      assert buffer1 == part1

      {msgs2, buffer2} = Stdio.handle_data(buffer1, part2)
      assert length(msgs2) == 1
      assert hd(msgs2)["jsonrpc"] == "2.0"
      assert buffer2 == ""
    end

    test "handles multiple messages in one chunk" do
      input = "{\"id\": 1}\n{\"id\": 2}\n"
      {msgs, buffer} = Stdio.handle_data("", input)

      assert length(msgs) == 2
      assert Enum.at(msgs, 0)["id"] == 1
      assert Enum.at(msgs, 1)["id"] == 2
      assert buffer == ""
    end

    test "ignores partial/invalid lines but keeps rest" do
      input = "LOG: starting...\n{\"id\": 1}\n"
      # The log line is invalid JSON, should be dropped with warning
      {msgs, buffer} = Stdio.handle_data("", input)

      assert length(msgs) == 1
      assert hd(msgs)["id"] == 1
      assert buffer == ""
    end
  end
end
