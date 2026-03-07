defmodule Pincer.Core.Cron do
  @moduledoc """
  Manages scheduled tasks for Pincer.
  """

  alias Pincer.Ports.Cron

  @doc "Creates a new scheduled job."
  def add(attrs), do: Cron.create_job(attrs)

  @doc "Lists all scheduled jobs."
  def list, do: Cron.list_jobs()

  @doc "Removes a scheduled job by ID."
  def remove(id), do: Cron.delete_job(id)

  @doc "Disables a scheduled job by ID."
  def disable(id), do: Cron.disable_job(id)

  @doc """
  Schedules a one-shot prompt to fire after `seconds_from_now`.

  Creates a non-recurring job that delivers `message` to the given
  `session_id` at the computed future timestamp.
  """
  def schedule(session_id, message, seconds_from_now) do
    run_at = DateTime.add(DateTime.utc_now(), seconds_from_now, :second)
    add(%{
      name: "one_shot_#{System.unique_integer([:positive])}",
      cron_expression: nil,
      run_once_at: run_at,
      prompt: message,
      session_id: session_id,
      enabled: true
    })
  end
end
