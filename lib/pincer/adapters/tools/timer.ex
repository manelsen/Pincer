defmodule Pincer.Adapters.Tools.Timer do
  @moduledoc """
  Tool for Pincer to schedule reminders or volatile (one-off) tasks in the near future.
  """
  @behaviour Pincer.Ports.Tool

  @impl true
  def spec do
    %{
      name: "schedule_timer_delay",
      description:
        "Schedules a temporary (volatile) timer to delay an action by seconds or minutes. Ideal for requests like 'Remind me in X minutes', 'Wake up in a while'. Do not use for recurring tasks (use cron_job for that).",
      parameters: %{
        type: "object",
        properties: %{
          prompt: %{
            type: "string",
            description: "The instruction/message the agent should react to when time is up."
          },
          seconds: %{
            type: "integer",
            description: "Exact number of SECONDS from now for the trigger."
          }
        },
        required: ["prompt", "seconds"]
      }
    }
  end

  @impl true
  def execute(%{"prompt" => msg, "seconds" => sec, "session_id" => sid}) do
    # Spawns a lightweight OTP background process that sleeps and triggers the Session
    Task.start(fn ->
      Process.sleep(sec * 1000)

      # Looks up the session PID
      session_tuple = Registry.lookup(Pincer.Core.Session.Registry, sid)

      case session_tuple do
        [{pid, _}] ->
          send(pid, {:cron_trigger, msg})

        [] ->
          # For short timers, we ignore if the session has somehow died
          :ok
      end
    end)

    {:ok, "Timer activated! Will run in exactly #{sec} seconds independently."}
  end

  def execute(args) do
    missing = ["prompt", "seconds"] |> Enum.reject(&Map.has_key?(args, &1))

    {:error,
     "schedule_timer_delay is missing required parameters: #{Enum.join(missing, ", ")}. Please provide 'prompt' (string) and 'seconds' (integer)."}
  end
end
