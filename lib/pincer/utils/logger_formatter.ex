defmodule Pincer.Utils.LoggerFormatter do
  @moduledoc """
  Custom Logger Formatter for Pincer.
  Adds colors and structured layout to console logs.
  """

  def format(level, message, timestamp, metadata) do
    time = format_timestamp(timestamp)
    level_tag = format_level(level)
    meta = format_metadata(metadata)
    
    # ANSI Colors
    reset = "\e[0m"
    gray = "\e[90m"
    
    # Example Output: 22:15:01 [INFO] [session:123] Hello world
    "#{gray}#{time}#{reset} #{level_tag} #{meta}#{message}\n"
  end

  defp format_level(level) do
    case level do
      :info -> "\e[36m[INFO]\e[0m"
      :error -> "\e[31m[ERROR]\e[0m"
      :warning -> "\e[33m[WARN]\e[0m"
      :debug -> "\e[35m[DEBUG]\e[0m"
      _ -> "[#{level |> to_string() |> String.upcase()}]"
    end
  end

  defp format_metadata(metadata) do
    session = Keyword.get(metadata, :session_id)
    project = Keyword.get(metadata, :project_id)
    
    yellow = "\e[33m"
    reset = "\e[0m"

    cond do
      session && project -> "#{yellow}[S:#{session}|P:#{project}]#{reset} "
      session -> "#{yellow}[S:#{session}]#{reset} "
      project -> "#{yellow}[P:#{project}]#{reset} "
      true -> ""
    end
  end

  defp format_timestamp({date, {h, m, s, ms}}) do
    {_y, month, d} = date
    "#{pad(d)}/#{pad(month)} #{pad(h)}:#{pad(m)}:#{pad(s)}.#{pad_ms(ms)}"
  end

  defp pad(n) when n < 10, do: "0#{n}"
  defp pad(n), do: to_string(n)

  defp pad_ms(n) when n < 10, do: "00#{n}"
  defp pad_ms(n) when n < 100, do: "0#{n}"
  defp pad_ms(n), do: to_string(n)
end
