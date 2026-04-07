defmodule Pincer.Core.Skills.ManifestTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.Skills.Manifest

  describe "parse/1" do
    test "parses valid frontmatter and body" do
      content = """
      ---
      name: web-search
      version: "1.0.0"
      description: Search the web for current information
      requirements:
        - binary: curl
      provides:
        - tool: search_web
          description: Search the web for a query
      ---
      # Web Search Skill

      Instructions for the agent on how to use web search.
      """

      assert {:ok, manifest} = Manifest.parse(content)
      assert manifest.name == "web-search"
      assert manifest.version == "1.0.0"
      assert manifest.description == "Search the web for current information"
      assert length(manifest.requirements) == 1
      assert [%{"binary" => "curl"}] = manifest.requirements
      assert length(manifest.provides) == 1

      assert [%{"tool" => "search_web", "description" => "Search the web for a query"}] =
               manifest.provides

      assert manifest.body =~ "Instructions for the agent"
    end

    test "returns error on invalid YAML" do
      content = """
      ---
      name: [invalid yaml {{{{
      ---
      body
      """

      assert {:error, _} = Manifest.parse(content)
    end

    test "provides defaults for missing fields" do
      content = """
      ---
      name: minimal
      ---
      Body here.
      """

      assert {:ok, manifest} = Manifest.parse(content)
      assert manifest.name == "minimal"
      assert manifest.version == "0.1.0"
      assert manifest.description == ""
      assert manifest.requirements == []
      assert manifest.provides == []
    end

    test "parses provides tool list correctly" do
      content = """
      ---
      name: multi-tool
      provides:
        - tool: search
          description: Search things
        - tool: summarize
          description: Summarize content
      ---
      body
      """

      assert {:ok, manifest} = Manifest.parse(content)
      assert length(manifest.provides) == 2

      tools = Enum.map(manifest.provides, & &1["tool"])
      assert "search" in tools
      assert "summarize" in tools
    end

    test "returns error when name is missing" do
      content = """
      ---
      version: "1.0.0"
      ---
      body
      """

      assert {:error, :missing_name} = Manifest.parse(content)
    end
  end
end
