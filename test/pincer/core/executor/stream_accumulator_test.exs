defmodule Pincer.Core.Executor.StreamAccumulatorTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.Executor.StreamAccumulator

  test "accumulates visible tokens, emits them to callback, and ignores non-delta chunks" do
    test_pid = self()

    stream = [
      %{"choices" => []},
      %{"choices" => [%{"delta" => %{"content" => "Hello "}}]},
      %{"choices" => [%{"delta" => %{"content" => "world!"}}]},
      %{"choices" => [%{"delta" => %{}}]}
    ]

    msg = StreamAccumulator.consume(stream, &send(test_pid, {:token, &1}))

    assert_received {:token, "Hello "}
    assert_received {:token, "world!"}
    refute_received {:token, _}

    assert msg["role"] == "assistant"
    assert msg["content"] == "Hello world!"
    assert msg["streamed_text"] == "Hello world!"
    assert msg["tool_calls"] == nil
  end

  test "filters internal thinking/tool tags during streaming and flushes remaining visible text" do
    test_pid = self()

    stream = [
      %{"choices" => [%{"delta" => %{"content" => "Intro <thin"}}]},
      %{"choices" => [%{"delta" => %{"content" => "king>secret</thinking> Visible"}}]},
      %{"choices" => [%{"delta" => %{"content" => " tail"}}]}
    ]

    msg = StreamAccumulator.consume(stream, &send(test_pid, {:token, &1}))

    assert_received {:token, "Intro "}
    assert_received {:token, " tail"}
    refute_received {:token, "secret"}

    assert msg["content"] =~ "Intro"
    assert msg["content"] =~ "Visible tail"
    assert msg["streamed_text"] == "Intro  Visible tail"
  end

  test "hides reasoning-only response when content has only whitespace" do
    stream = [
      %{
        "choices" => [
          %{"delta" => %{"reasoning_content" => "internal chain", "content" => "   "}}
        ]
      }
    ]

    msg = StreamAccumulator.consume(stream)
    assert msg["content"] == nil
    assert msg["streamed_text"] == ""
  end

  test "merges streamed tool call deltas sorted by index and handles map arguments" do
    stream = [
      %{
        "choices" => [
          %{
            "delta" => %{
              "tool_calls" => [
                %{
                  "index" => 1,
                  "id" => "c2",
                  "function" => %{"name" => "b", "arguments" => %{"x" => 1}}
                },
                %{
                  "index" => 0,
                  "id" => "c1",
                  "function" => %{"name" => "read_", "arguments" => "{\"p\":"}
                }
              ]
            }
          }
        ]
      },
      %{
        "choices" => [
          %{
            "delta" => %{
              "tool_calls" => [
                %{"index" => 0, "function" => %{"name" => "file", "arguments" => "\"a.ex\"}"}}
              ]
            }
          }
        ]
      }
    ]

    msg = StreamAccumulator.consume(stream)

    assert msg["tool_calls"] == [
             %{
               "id" => "c1",
               "type" => "function",
               "function" => %{"name" => "read_file", "arguments" => ~s({"p":"a.ex"})}
             },
             %{
               "id" => "c2",
               "type" => "function",
               "function" => %{"name" => "b", "arguments" => ~s({"x":1})}
             }
           ]
  end
end
