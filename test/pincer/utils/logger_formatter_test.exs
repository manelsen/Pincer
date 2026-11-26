defmodule Pincer.Utils.LoggerFormatterTest do
  use ExUnit.Case, async: true

  alias Pincer.Utils.LoggerFormatter

  @timestamp {{2026, 11, 25}, {14, 5, 9, 42}}

  test "formats info, error, warning, debug, and unknown levels with ANSI tags" do
    assert LoggerFormatter.format(:info, "booted\n", @timestamp, []) ==
             "\e[90m25/11 14:05:09.042\e[0m \e[36m[INFO]\e[0m booted\n"

    assert LoggerFormatter.format(:error, "failed", @timestamp, []) ==
             "\e[90m25/11 14:05:09.042\e[0m \e[31m[ERROR]\e[0m failed\n"

    assert LoggerFormatter.format(:warning, "slow", @timestamp, []) ==
             "\e[90m25/11 14:05:09.042\e[0m \e[33m[WARN]\e[0m slow\n"

    assert LoggerFormatter.format(:debug, "trace", @timestamp, []) ==
             "\e[90m25/11 14:05:09.042\e[0m \e[35m[DEBUG]\e[0m trace\n"

    assert LoggerFormatter.format(:notice, "note", @timestamp, []) ==
             "\e[90m25/11 14:05:09.042\e[0m [NOTICE] note\n"
  end

  test "formats session and project metadata in yellow" do
    assert LoggerFormatter.format(:info, "hi", @timestamp, session_id: "s1") ==
             "\e[90m25/11 14:05:09.042\e[0m \e[36m[INFO]\e[0m \e[33m[S:s1]\e[0m hi\n"

    assert LoggerFormatter.format(:info, "hi", @timestamp, project_id: "p1") ==
             "\e[90m25/11 14:05:09.042\e[0m \e[36m[INFO]\e[0m \e[33m[P:p1]\e[0m hi\n"

    assert LoggerFormatter.format(:info, "hi", @timestamp, session_id: "s1", project_id: "p1") ==
             "\e[90m25/11 14:05:09.042\e[0m \e[36m[INFO]\e[0m \e[33m[S:s1|P:p1]\e[0m hi\n"
  end
end
