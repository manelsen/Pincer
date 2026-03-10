defmodule Pincer.Adapters.Tools.Scheduler do
  @moduledoc """
  Pincer's definitive tool for scheduling proactive tasks in the future
  using Cron notation in the PostgreSQL database.
  """
  @behaviour Pincer.Ports.Tool
  alias Pincer.Ports.Cron

  def spec do
    [
      %{
        name: "schedule_reminder",
        description: "Schedules a one-time task or reminder in a given amount of seconds.",
        parameters: %{
          type: "object",
          properties: %{
            message: %{type: "string", description: "What to do or remember."},
            seconds: %{type: "integer", description: "Seconds from now to trigger."}
          },
          required: ["message", "seconds"]
        }
      },
      %{
        name: "schedule_cron_job",
        description:
          "Schedules a RECURRING routine (e.g., every day, every hour) using Cron notation. DO NOT use for one-time reminders like 'in X minutes'.",
        parameters: %{
          type: "object",
          properties: %{
            name: %{type: "string", description: "Short name."},
            cron_expression: %{
              type: "string",
              description: "E.g., '0 8 * * *' (daily), '*/5 * * * *' (every 5 min)."
            },
            prompt: %{type: "string", description: "What the agent should do when triggered."}
          },
          required: ["name", "cron_expression", "prompt"]
        }
      },
      %{
        name: "list_cron_jobs",
        description: "Lists all active recurring schedules.",
        parameters: %{type: "object", properties: %{}}
      },
      %{
        name: "delete_cron_job",
        description: "Removes a recurring schedule permanently.",
        parameters: %{
          type: "object",
          properties: %{
            id: %{type: "string", description: "Job UUID obtained via list_cron_jobs."}
          },
          required: ["id"]
        }
      }
    ]
  end

  def execute(%{
        "tool_name" => "schedule_reminder",
        "message" => message,
        "seconds" => seconds,
        "session_id" => sid
      }) do
    case Pincer.Core.Cron.schedule(sid, message, seconds) do
      {:ok, _} -> {:ok, "Reminder scheduled for #{seconds} seconds from now."}
      _ -> {:error, "Failed to schedule reminder."}
    end
  end

  def execute(%{
        "tool_name" => "schedule_cron_job",
        "name" => name,
        "cron_expression" => cron,
        "prompt" => p,
        "session_id" => sid
      }) do
    case Cron.create_job(%{name: name, cron_expression: cron, prompt: p, session_id: sid}) do
      {:ok, job} ->
        {:ok,
         "Schedule '#{job.name}' (ID: #{job.id}) registered! Next execution: #{job.next_run_at}"}

      {:error, changeset} ->
        errors =
          changeset.errors |> Enum.map(fn {f, {m, _}} -> "#{f}: #{m}" end) |> Enum.join(", ")

        {:error, "Error: #{errors}"}
    end
  end

  def execute(%{"tool_name" => "list_cron_jobs"}) do
    jobs = Cron.list_jobs()

    if Enum.empty?(jobs) do
      {:ok, "No schedules found."}
    else
      text =
        Enum.map(jobs, fn j ->
          disabled_tag = if !j.enabled, do: "(DISABLED)", else: ""
          "- [#{j.id}] #{j.name}: #{j.cron_expression} (Next: #{j.next_run_at}) #{disabled_tag}"
        end)
        |> Enum.join("\n")

      {:ok, "Active schedules:\n#{text}"}
    end
  end

  def execute(%{"tool_name" => "delete_cron_job", "id" => id}) do
    case Cron.delete_job(id) do
      {:ok, _} -> {:ok, "Job #{id} removed successfully."}
      {:error, _} -> {:error, "Could not find or remove job #{id}."}
    end
  end
end
