defmodule Pincer.Docs.ReadmeIntegrityTest do
  @moduledoc """
  Guards `README.md`, `docs/README.md`, and `docs/architecture/` against broken
  relative links, unbalanced fences, missing Mermaid diagrams, and stale claims.
  """
  use ExUnit.Case, async: true

  @readme "README.md"
  @docs_index "docs/README.md"
  @boundaries_report "docs/architecture/2026-03-13-architecture-boundaries-report.md"

  test "README.md and docs/README.md exist" do
    assert File.exists?(@readme)
    assert File.exists?(@docs_index)
  end

  test "all relative markdown and image links resolve to files on disk" do
    for doc_path <- [@readme, @docs_index, @boundaries_report] do
      content = File.read!(doc_path)
      base_dir = Path.dirname(doc_path)

      links =
        Regex.scan(~r/!?\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)/, content, capture: :all_but_first)
        |> List.flatten()
        |> Enum.reject(&external_or_anchor?/1)

      assert links != [], "Expected relative links in #{doc_path}"

      missing =
        Enum.reject(links, fn target ->
          path = target |> String.split("#", parts: 2) |> hd()
          resolved = if base_dir == ".", do: path, else: Path.expand(path, base_dir)
          File.exists?(resolved)
        end)

      assert missing == [],
             "Found broken relative links in #{doc_path}: #{inspect(missing)}"
    end
  end

  test "README.md includes Mermaid architecture diagrams and balanced code fences" do
    content = File.read!(@readme)

    fence_count = Regex.scan(~r/^```/m, content) |> length()
    assert rem(fence_count, 2) == 0, "Unbalanced fenced code blocks in #{@readme}"

    mermaid_blocks =
      Regex.scan(~r/```mermaid\n([^\n]+)/, content, capture: :all_but_first)
      |> List.flatten()

    assert length(mermaid_blocks) >= 4,
           "Expected at least 4 Mermaid diagrams in #{@readme}, found #{length(mermaid_blocks)}"

    Enum.each(mermaid_blocks, fn header ->
      assert header =~ ~r/^(flowchart (?:LR|TD)|sequenceDiagram)/,
             "Unsupported or invalid Mermaid header in #{@readme}: #{inspect(header)}"
    end)
  end

  test "README.md contains no stale 0.1.0 subsystem claims" do
    content = File.read!(@readme)

    refute content =~ "web_visibility"
    refute content =~ "Providers.Minimax"
    refute content =~ "max recursion depth of 25"
    refute content =~ "Ports may only depend on Infra"
    refute content =~ "Health checks + GitHub watcher"
  end

  defp external_or_anchor?(target) do
    String.starts_with?(target, ["http://", "https://", "#", "mailto:"])
  end
end
