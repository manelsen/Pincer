defmodule Pincer.Core.Skills.PromptIndexTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.AgentPaths
  alias Pincer.Core.Skills.PromptIndex

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "pincer_prompt_idx_#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)
    {:ok, workspace: workspace}
  end

  test "returns empty string when no skills exist", %{workspace: workspace} do
    assert PromptIndex.build(workspace, shared_dir: nil, bundled_dir: nil) == ""
  end

  test "discovers workspace skills and formats bounded index filtering unmet requirements", %{
    workspace: workspace
  } do
    skills_dir = AgentPaths.skills_dir(workspace)

    # Skill with met requirements
    ready_dir = Path.join(skills_dir, "mix-qa-gate")
    File.mkdir_p!(ready_dir)

    File.write!(Path.join(ready_dir, "SKILL.md"), """
    ---
    name: mix-qa-gate
    version: "0.1.0"
    description: Run mix qa before finalizing changes
    requirements:
      - binary: sh
    ---
    # Mix QA Gate
    Run `mix test`.
    """)

    # Skill with unmet binary requirement
    missing_dir = Path.join(skills_dir, "missing-cli")
    File.mkdir_p!(missing_dir)

    File.write!(Path.join(missing_dir, "SKILL.md"), """
    ---
    name: missing-cli
    version: "0.1.0"
    description: Needs impossible binary
    requirements:
      - binary: totally_nonexistent_pincer_bin_999
    ---
    # Unmet
    """)

    section = PromptIndex.build(workspace, shared_dir: nil, bundled_dir: nil)

    assert String.contains?(section, "## LEARNED & AVAILABLE SKILLS:")
    assert String.contains?(section, "mix-qa-gate")
    assert String.contains?(section, "Run mix qa before finalizing changes")
    refute String.contains?(section, "missing-cli")
  end

  test "enforces max_chars budget and strips invisible unicode control chars", %{
    workspace: workspace
  } do
    skills_dir = AgentPaths.skills_dir(workspace)

    for i <- 1..10 do
      dir = Path.join(skills_dir, "skill-#{i}")
      File.mkdir_p!(dir)

      File.write!(Path.join(dir, "SKILL.md"), """
      ---
      name: skill-#{i}
      version: "0.1.0"
      description: "Clean\u202E description #{String.duplicate("word ", 25)}"
      ---
      # Body #{i}
      """)
    end

    section = PromptIndex.build(workspace, shared_dir: nil, bundled_dir: nil, max_chars: 450)
    assert String.length(section) <= 450
    refute String.contains?(section, "\u202E")
  end
end
