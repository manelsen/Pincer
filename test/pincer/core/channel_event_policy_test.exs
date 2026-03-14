defmodule Pincer.Core.ChannelEventPolicyTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.ChannelEventPolicy

  test "classifies sub-agent textual statuses" do
    assert ChannelEventPolicy.status_kind("⚙️ Sub-Agent a1 running: web.") == :subagent
    assert ChannelEventPolicy.status_kind("Status update") == :plain
  end

  test "builds transport-specific error envelopes" do
    assert ChannelEventPolicy.error_message(:telegram, "boom") == "❌ <b>Agent Error</b>: boom"
    assert ChannelEventPolicy.error_message(:discord, "boom") == "❌ **Agent Error**: boom"
    assert ChannelEventPolicy.error_message(:whatsapp, "boom") == "Agent error: boom"
  end
end
