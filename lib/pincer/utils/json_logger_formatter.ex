defmodule Pincer.Utils.JsonLoggerFormatter do
  @moduledoc """
  Formats log entries as JSON for structured log aggregation (ELK, Datadog, etc.).
  Replaces the ANSI formatter in production environments.
  """

  def format(level, message, timestamp, metadata) do
    {{year, month, day}, {hour, minute, second, ms}} = shift_utc(timestamp)

    iso_ts =
      :io_lib.format(
        "~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0B.~3..0BZ",
        [year, month, day, hour, minute, second, ms]
      )
      |> IO.iodata_to_binary()

    base = %{
      "timestamp" => iso_ts,
      "level" => Atom.to_string(level),
      "message" => IO.iodata_to_binary(message)
    }

    meta =
      metadata
      |> Enum.reduce(base, fn
        {k, v}, acc when is_binary(v) or is_atom(v) or is_number(v) ->
          Map.put(acc, Atom.to_string(k), v)

        {k, v}, acc when is_list(v) ->
          Map.put(acc, Atom.to_string(k), inspect(v))

        _, acc ->
          acc
      end)

    case Jason.encode(meta) do
      {:ok, json} -> json <> "\n"
      _ -> "#{iso_ts} [#{level}] #{message}\n"
    end
  end

  defp shift_utc({date, {h, m, s, ms}}) do
    offset = Application.get_env(:pincer, :log_utc_offset, 0)
    greg_secs = :calendar.datetime_to_gregorian_seconds({date, {h, m, s}})
    shifted = greg_secs + offset * 3600
    {new_date, {new_h, new_m, new_s}} = :calendar.gregorian_seconds_to_datetime(shifted)
    {new_date, {new_h, new_m, new_s, ms}}
  end
end
