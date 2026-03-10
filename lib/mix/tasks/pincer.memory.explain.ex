defmodule Mix.Tasks.Pincer.Memory.Explain do
  @moduledoc """
  Explains what the memory recall pipeline would return for a query.

  Usage:

      mix pincer.memory.explain --query "deploy timeout webhook"
      mix pincer.memory.explain --query "..." --workspace-path workspaces/demo --no-semantic
  """

  use Mix.Task
  use Boundary, classify_to: Pincer.Mix

  alias Pincer.Core.MemoryDiagnostics

  @shortdoc "Explain runtime memory recall for a query"

  @switches [
    query: :string,
    workspace_path: :string,
    limit: :integer,
    session_id: :string,
    no_semantic: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      invalid_flags = Enum.map_join(invalid, ", ", fn {k, _} -> "--#{k}" end)
      Mix.raise("Invalid flags for pincer.memory.explain: #{invalid_flags}")
    end

    query = String.trim(opts[:query] || "")

    if query == "" do
      Mix.raise("--query is required for pincer.memory.explain")
    end

    [
      workspace_path: opts[:workspace_path] || Process.get(:workspace_path, File.cwd!()),
      limit: opts[:limit] || 5,
      session_id: opts[:session_id]
    ]
    |> maybe_disable_semantic(opts[:no_semantic] == true)
    |> then(&MemoryDiagnostics.explain(query, &1))
    |> print_explanation()
  end

  defp maybe_disable_semantic(opts, false), do: opts

  defp maybe_disable_semantic(opts, true) do
    Keyword.put(opts, :embedding_fun, fn _query -> {:error, :disabled} end)
  end

  defp print_explanation(explanation) do
    Mix.shell().info("Pincer Memory Explain")
    Mix.shell().info("Query: #{explanation.query}")
    Mix.shell().info("Eligible: #{yes_no(explanation.eligible?)}")

    Mix.shell().info(
      "Source hits: messages=#{length(explanation.messages)} documents=#{length(explanation.documents)} semantic=#{length(explanation.semantic)}"
    )

    Mix.shell().info("Prompt chars: #{String.length(explanation.prompt_block)}")

    if explanation.user_memory != "" do
      Mix.shell().info("User memory:")
      Mix.shell().info(explanation.user_memory)
    end

    Mix.shell().info("Hits")

    Enum.each(explanation.hits, fn hit ->
      Mix.shell().info(
        "- #{hit.source} score=#{format_score(Map.get(hit, :score))} citation=#{hit.citation}"
      )
    end)

    Mix.shell().info("Related sessions")

    Enum.each(explanation.sessions, fn session ->
      Mix.shell().info(
        "- #{session.session_id} hits=#{session.hit_count} preview=#{String.slice(session.preview || "", 0, 120)}"
      )
    end)

    Enum.each(explanation.notes, &Mix.shell().info("Note: #{&1}"))
  end

  defp yes_no(true), do: "yes"
  defp yes_no(false), do: "no"

  defp format_score(nil), do: "-"
  defp format_score(score) when is_float(score), do: :erlang.float_to_binary(score, decimals: 3)
  defp format_score(score), do: to_string(score)
end
