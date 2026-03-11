defmodule Pincer.Adapters.Cron.SchedulerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Pincer.Adapters.Cron.Scheduler

  test "keeps scheduler alive when cron_jobs table is missing" do
    missing_table_fetcher = fn ->
      raise %RuntimeError{message: "undefined table: cron_jobs"}
    end

    parent = self()

    first_log =
      capture_log(fn ->
        {:ok, pid} =
          start_supervised(
            {Scheduler,
             [
               name: nil,
               tick_interval: :timer.hours(1),
               due_jobs_fetcher: missing_table_fetcher,
               next_run_updater: fn _job -> :ok end,
               job_dispatcher: fn _job -> :ok end
             ]}
          )

        send(parent, {:started, pid})
        # Wait for the async tick to log (generous budget for loaded CI)
        Process.sleep(200)
      end)

    pid =
      receive do
        {:started, p} -> p
      end

    assert Process.alive?(pid)
    assert first_log =~ "cron_jobs table missing"

    second_log =
      capture_log(fn ->
        send(pid, :tick)
        Process.sleep(100)
      end)

    refute second_log =~ "cron_jobs table missing"
  end

  test "dispatches and reschedules due jobs on successful tick" do
    parent = self()
    job = %{id: "job-1", name: "demo", session_id: "telegram:1", prompt: "ping"}

    {:ok, pid} =
      start_supervised(
        {Scheduler,
         [
           name: nil,
           tick_interval: :timer.hours(1),
           due_jobs_fetcher: fn -> [job] end,
           next_run_updater: fn j ->
             send(parent, {:rescheduled, j.id})
             :ok
           end,
           job_dispatcher: fn j ->
             send(parent, {:dispatched, j.id})
             :ok
           end
         ]}
      )

    send(pid, :tick)

    assert_receive {:dispatched, "job-1"}, 200
    assert_receive {:rescheduled, "job-1"}, 200
  end
end
