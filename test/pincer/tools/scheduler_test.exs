defmodule Pincer.Adapters.Tools.SchedulerTest do
  use ExUnit.Case, async: true

  alias Pincer.Adapters.Tools.Scheduler

  describe "execute/1 error paths" do
    test "reports the missing required parameters for schedule_reminder" do
      assert {:error, message} = Scheduler.execute(%{"tool_name" => "schedule_reminder"})

      assert message =~ "missing required parameters"
      assert message =~ "message"
      assert message =~ "seconds"
      assert message =~ "session_id"
    end

    test "reports the missing required parameters for schedule_cron_job" do
      assert {:error, message} =
               Scheduler.execute(%{
                 "tool_name" => "schedule_cron_job",
                 "name" => "standup"
               })

      assert message =~ "cron_expression"
      assert message =~ "prompt"
      assert message =~ "session_id"
    end

    test "reports the missing id for delete_cron_job" do
      assert {:error, message} = Scheduler.execute(%{"tool_name" => "delete_cron_job"})
      assert message =~ "id"
    end

    test "rejects unknown tool names without claiming a missing parameter" do
      assert {:error, message} = Scheduler.execute(%{"tool_name" => "nope"})
      assert message == "Unknown scheduler tool: nope"
    end

    test "rejects calls with no tool_name" do
      assert {:error, message} = Scheduler.execute(%{"name" => "x"})
      assert message =~ "without 'tool_name'"
    end
  end
end
