defmodule Pincer.Core.Skills.LoaderTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.Skills.Loader

  describe "discover/1 from single tier" do
    test "discovers skills from bundled tier" do
      # Use the test fixture directory
      bundled = Path.join([__DIR__, "..", "..", "..", "..", "fixtures", "skills", "bundled"])

      skills = Loader.discover(bundled: bundled, shared: nil, workspace: nil)

      names = Enum.map(skills, & &1.name)
      assert "hello" in names
    end

    test "returns empty list for nonexistent directory" do
      skills = Loader.discover(bundled: "/nonexistent/path", shared: nil, workspace: nil)
      assert skills == []
    end
  end

  describe "discover/1 with tier override" do
    test "shared overrides bundled by name" do
      bundled = Path.join([__DIR__, "..", "..", "..", "..", "fixtures", "skills", "bundled"])
      shared = Path.join([__DIR__, "..", "..", "..", "..", "fixtures", "skills", "shared"])

      skills = Loader.discover(bundled: bundled, shared: shared, workspace: nil)

      # "hello" exists in both bundled (1.0.0) and shared (2.0.0) — shared wins
      hello = Enum.find(skills, &(&1.name == "hello"))
      assert hello != nil
      assert hello.version == "2.0.0"
    end

    test "workspace overrides all by name" do
      bundled = Path.join([__DIR__, "..", "..", "..", "..", "fixtures", "skills", "bundled"])
      shared = Path.join([__DIR__, "..", "..", "..", "..", "fixtures", "skills", "shared"])
      workspace = Path.join([__DIR__, "..", "..", "..", "..", "fixtures", "skills", "workspace"])

      skills = Loader.discover(bundled: bundled, shared: shared, workspace: workspace)

      # "hello" exists in all three tiers — workspace (3.0.0) wins
      hello = Enum.find(skills, &(&1.name == "hello"))
      assert hello != nil
      assert hello.version == "3.0.0"

      # "workspace-only" exists only in workspace
      ws_only = Enum.find(skills, &(&1.name == "workspace-only"))
      assert ws_only != nil
    end
  end

  describe "check_requirements/1" do
    test "flags missing requirement binary" do
      manifest = %{
        name: "test",
        requirements: [%{"binary" => "nonexistent_binary_xyz_123"}]
      }

      issues = Loader.check_requirements(manifest)
      assert length(issues) == 1
      assert hd(issues).type == :missing_binary
      assert hd(issues).binary == "nonexistent_binary_xyz_123"
    end

    test "returns empty list when all requirements met" do
      manifest = %{
        name: "test",
        requirements: [%{"binary" => "sh"}]
      }

      issues = Loader.check_requirements(manifest)
      assert issues == []
    end

    test "returns empty for no requirements" do
      manifest = %{name: "test", requirements: []}
      assert Loader.check_requirements(manifest) == []
    end
  end
end
