defmodule Mix.Tasks.Pincer.Memory.Report do
  @moduledoc """
  Prints a human-readable runtime and persistence memory report.

  Usage:

      mix pincer.memory.report
      mix pincer.memory.report --limit 10
  """

  use Mix.Task
  use Boundary, classify_to: Pincer.Mix

  alias Pincer.Core.MemoryDiagnostics

  @shortdoc "Print memory runtime/persistence diagnostics"

  @switches [
    limit: :integer
  ]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      invalid_flags = Enum.map_join(invalid, ", ", fn {k, _} -> "--#{k}" end)
      Mix.raise("Invalid flags for pincer.memory.report: #{invalid_flags}")
    end

    opts[:limit]
    |> Kernel.||(5)
    |> then(&MemoryDiagnostics.report(limit: &1))
    |> print_report()
  end

  defp print_report(report) do
    Mix.shell().info("Pincer Memory Report")
    Mix.shell().info("")
    Mix.shell().info("Runtime")

    Mix.shell().info(
      "Recall: count=#{report.snapshot.recall.count} eligible=#{report.snapshot.recall.eligible_count} hits=#{report.snapshot.recall.total_hits} avg_ms=#{format_float(report.snapshot.recall.avg_duration_ms)} prompt_chars=#{report.snapshot.recall.prompt_chars}"
    )

    Mix.shell().info(
      "Search: count=#{report.snapshot.search.count} hits=#{report.snapshot.search.total_hits} avg_ms=#{format_float(report.snapshot.search.avg_duration_ms)}"
    )

    Enum.each(
      report.snapshot.search.by_source |> Enum.sort_by(fn {source, _} -> to_string(source) end),
      fn {source, source_report} ->
        Mix.shell().info(
          "- #{source}: count=#{source_report.count} hits=#{source_report.total_hits} avg_ms=#{format_float(source_report.avg_duration_ms)} skipped=#{source_report.skipped_count} errors=#{source_report.error_count}"
        )
      end
    )

    Mix.shell().info("")
    Mix.shell().info("Persistence")

    Mix.shell().info(
      "Documents: total=#{report.inventory.total_memories} forgotten=#{report.inventory.forgotten_memories}"
    )

    Enum.each(report.inventory.by_type |> Enum.sort_by(fn {type, _} -> type end), fn {type, count} ->
      Mix.shell().info("- #{type}: #{count}")
    end)

    Mix.shell().info("Top memories")

    Enum.each(report.inventory.top_memories, fn document ->
      Mix.shell().info(
        "- #{document.source} type=#{document.memory_type} accesses=#{document.access_count} importance=#{document.importance} session=#{document.session_id || "-"} forgotten=#{document.forgotten?}"
      )
    end)

    Mix.shell().info("Top sessions")

    Enum.each(report.inventory.top_sessions, fn session ->
      Mix.shell().info("- #{session.session_id}: #{session.document_count}")
    end)
  end

  defp format_float(number) when is_float(number),
    do: :erlang.float_to_binary(number, decimals: 1)

  defp format_float(number) when is_integer(number), do: format_float(number / 1)
end
