defmodule Pincer.Core.TurnOutcomePolicyTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.TurnOutcomePolicy

  test "prefers explicit final text when present" do
    assert {:final_text, "Final"} =
             TurnOutcomePolicy.resolve(%{
               final_text: "Final",
               streamed_text: "Partial",
               tool_messages: [],
               tool_call_count: 0
             })
  end

  test "falls back to streamed text when final text is empty" do
    assert {:final_text, "Streamed"} =
             TurnOutcomePolicy.resolve(%{
               final_text: nil,
               streamed_text: "Streamed",
               tool_messages: [],
               tool_call_count: 0
             })
  end

  test "builds tool-only summary when no visible answer exists after tools" do
    assert {:tool_summary, summary} =
             TurnOutcomePolicy.resolve(%{
               final_text: nil,
               streamed_text: nil,
               tool_messages: [
                 %{"name" => "file_system", "content" => "Files in workspace\nREADME.md"}
               ],
               tool_call_count: 0
             })

    assert summary =~ "Ferramentas utilizadas: file_system"
    assert summary =~ "README.md"
  end

  test "returns empty response error when nothing user-visible exists" do
    assert {:error, :empty_response} =
             TurnOutcomePolicy.resolve(%{
               final_text: nil,
               streamed_text: nil,
               tool_messages: [],
               tool_call_count: 0
             })
  end
end
