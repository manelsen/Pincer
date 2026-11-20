defmodule Pincer.Adapters.Tools.Timer do
  @moduledoc """
  Tool for Pincer to schedule reminders or volatile (one-off) tasks in the near future.
  """
  @behaviour Pincer.Ports.Tool

  alias Pincer.Adapters.Tools.TimerServer

  @max_seconds 86_400

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
            description:
              "Exact number of SECONDS from now for the trigger (1 to #{@max_seconds})."
          }
        },
        required: ["prompt", "seconds"]
      }
    }
  end

  @impl true
  def execute(args, context \\ %{})

  def execute(args, context) when is_map(args) and is_map(context) do
    with {:ok, prompt} <- fetch_prompt(args),
         {:ok, seconds} <- fetch_seconds(args),
         {:ok, session_id} <- fetch_session_id(args, context),
         {:ok, _timer_id} <- schedule_timer(session_id, prompt, seconds * 1000) do
      {:ok, "Timer activated! Will run in exactly #{seconds} seconds independently."}
    end
  end

  def execute(_args, _context) do
    {:error, "schedule_timer_delay requires 'prompt' (string) and 'seconds' (integer)."}
  end

  defp fetch_prompt(%{"prompt" => prompt}) when is_binary(prompt) do
    case String.trim(prompt) do
      "" -> {:error, "schedule_timer_delay parameter 'prompt' cannot be empty."}
      _ -> {:ok, prompt}
    end
  end

  defp fetch_prompt(_),
    do: {:error, "schedule_timer_delay is missing required parameter: prompt."}

  defp fetch_seconds(%{"seconds" => seconds})
       when is_integer(seconds) and seconds >= 1 and seconds <= @max_seconds do
    {:ok, seconds}
  end

  defp fetch_seconds(%{"seconds" => _}) do
    {:error, "schedule_timer_delay 'seconds' must be an integer between 1 and #{@max_seconds}."}
  end

  defp fetch_seconds(_),
    do: {:error, "schedule_timer_delay is missing required parameter: seconds."}

  defp fetch_session_id(args, context) do
    sid =
      Map.get(context, "session_id") ||
        Map.get(context, :session_id) ||
        Map.get(args, "session_id") ||
        Map.get(args, :session_id)

    if is_binary(sid) and String.trim(sid) != "" do
      {:ok, sid}
    else
      {:error, "schedule_timer_delay requires a valid session_id in context."}
    end
  end

  defp schedule_timer(session_id, prompt, delay_ms) do
    TimerServer.schedule(timer_server(), session_id, prompt, delay_ms)
  catch
    :exit, _reason -> {:error, "Timer service unavailable."}
  end

  defp timer_server do
    Application.get_env(:pincer, :timer_server, TimerServer)
  end
end
