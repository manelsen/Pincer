defmodule Pincer.Core.Cron do
  @moduledoc """
  Manages scheduled tasks for Pincer.
  """

  alias Pincer.Ports.Cron

  def add(attrs), do: Cron.create_job(attrs)
  def list, do: Cron.list_jobs()
  def remove(id), do: Cron.delete_job(id)
  def disable(id), do: Cron.disable_job(id)

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
