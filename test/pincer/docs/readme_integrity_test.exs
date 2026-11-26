defmodule Pincer.Docs.ReadmeIntegrityTest do
  @moduledoc """
  Guards `README.md`, `docs/README.md`, `docs/assets/*.svg`, and `docs/architecture/`
  against broken relative links or asset references, malformed SVG XML,
  unbalanced fences, invalid Mermaid diagrams, and stale claims.
  """
  use ExUnit.Case, async: true

  @readme "README.md"
  @docs_index "docs/README.md"
  @arch_overview "docs/architecture/overview.md"
  @boundaries_report "docs/architecture/2026-03-13-architecture-boundaries-report.md"

  @required_readme_assets [
    "docs/assets/pincer-hero.svg",
    "docs/assets/pincer-mascot.png",
    "docs/assets/pincer-runtime-pipeline.svg",
    "docs/assets/pincer-hexagonal-layers.svg",
    "docs/assets/pincer-agentic-turn.svg",
    "docs/assets/pincer-supervision-tree.svg",
    "docs/assets/pincer-memory-tiers.svg"
  ]

  test "README.md, docs/README.md, and docs/architecture/overview.md exist" do
    assert File.exists?(@readme)
    assert File.exists?(@docs_index)
    assert File.exists?(@arch_overview)
  end

  test "all relative markdown links and HTML img src paths resolve to non-empty files" do
    for doc_path <- [@readme, @docs_index, @arch_overview, @boundaries_report] do
      content = File.read!(doc_path)
      base_dir = Path.dirname(doc_path)

      md_links =
        Regex.scan(~r/!?\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)/, content, capture: :all_but_first)
        |> List.flatten()

      img_srcs =
        Regex.scan(~r/<img\b[^>]*\bsrc="([^"]+)"/, content, capture: :all_but_first)
        |> List.flatten()

      targets =
        (md_links ++ img_srcs)
        |> Enum.reject(&external_or_anchor?/1)
        |> Enum.uniq()

      assert targets != [], "Expected relative links or asset refs in #{doc_path}"

      broken =
        Enum.reject(targets, fn target ->
          path = target |> String.split("#", parts: 2) |> hd()
          resolved = if base_dir == ".", do: path, else: Path.expand(path, base_dir)
          File.exists?(resolved) and File.stat!(resolved).size > 0
        end)

      assert broken == [],
             "Found broken or empty relative links/assets in #{doc_path}: #{inspect(broken)}"
    end
  end

  test "README.md embeds all didactic visual assets, links to overview.md, and has balanced fences" do
    content = File.read!(@readme)

    assert_balanced_fences!(content, @readme)
    assert content =~ "docs/architecture/overview.md"

    missing_assets = Enum.reject(@required_readme_assets, &String.contains?(content, &1))

    assert missing_assets == [],
           "Expected #{@readme} to embed all visual assets, missing: #{inspect(missing_assets)}"
  end

  test "all SVG assets under docs/assets/ are well-formed with escaped entities" do
    svg_files = Path.wildcard("docs/assets/*.svg") |> Enum.sort()
    assert svg_files != []

    for svg_path <- svg_files do
      content = File.read!(svg_path) |> String.trim()

      assert String.starts_with?(content, "<svg"),
             "#{svg_path} must start with <svg"

      assert String.ends_with?(content, "</svg>"),
             "#{svg_path} must end with </svg>"

      open_count = Regex.scan(~r/<svg\b/, content) |> length()
      close_count = Regex.scan(~r/<\/svg>/, content) |> length()

      assert open_count == 1 and close_count == 1,
             "#{svg_path} must have balanced <svg>/</svg> tags (got #{open_count}/#{close_count})"

      without_comments = Regex.replace(~r/<!--.*?-->/s, content, "")

      bare_amps =
        Regex.scan(~r/&(?!(?:amp|lt|gt|quot|apos|#\d+|#x[0-9a-fA-F]+);)/, without_comments)

      assert bare_amps == [],
             "#{svg_path} contains unescaped '&' characters: #{inspect(bare_amps)}"
    end
  end

  test "docs/architecture/overview.md includes readable Mermaid architecture diagrams and balanced fences" do
    content = File.read!(@arch_overview)

    assert_balanced_fences!(content, @arch_overview)

    mermaid_blocks =
      Regex.scan(~r/```mermaid\n([^\n]+)/, content, capture: :all_but_first)
      |> List.flatten()

    assert length(mermaid_blocks) >= 4,
           "Expected at least 4 Mermaid diagrams in #{@arch_overview}, found #{length(mermaid_blocks)}"

    Enum.each(mermaid_blocks, fn header ->
      assert header =~ ~r/^(flowchart TD|sequenceDiagram)/,
             "Expected top-down flowchart TD or sequenceDiagram in #{@arch_overview}: #{inspect(header)}"
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

  defp assert_balanced_fences!(content, doc_path) do
    fence_count = Regex.scan(~r/^```/m, content) |> length()
    assert rem(fence_count, 2) == 0, "Unbalanced fenced code blocks in #{doc_path}"
  end

  defp external_or_anchor?(target) do
    String.starts_with?(target, ["http://", "https://", "#", "mailto:"])
  end
end
