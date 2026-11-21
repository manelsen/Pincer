defmodule Pincer.Storage.MemoryHelpersTest do
  use ExUnit.Case, async: true

  alias Pincer.Storage.MemoryHelpers

  defmodule FakeNode do
    defstruct [:data]
  end

  describe "build_memory_metadata/4" do
    test "normalizes the memory type and keeps provided options" do
      metadata =
        MemoryHelpers.build_memory_metadata("/w/a.ex", "def foo", :code, importance: 7)

      assert metadata["path"] == "/w/a.ex"
      assert metadata["content"] == "def foo"
      assert metadata["memory_type"] == "code"
      assert metadata["importance"] == 7
    end

    test "omits nil-valued options" do
      metadata = MemoryHelpers.build_memory_metadata("/w/a.ex", "x", :note, [])
      refute Map.has_key?(metadata, "forgotten_at")
      refute Map.has_key?(metadata, "line_start")
      refute Map.has_key?(metadata, "session_id")
    end

    test "defaults importance to 5 and access_count to 0" do
      metadata = MemoryHelpers.build_memory_metadata("/w/a.ex", "x", :note, [])
      assert metadata["importance"] == 5
      assert metadata["access_count"] == 0
    end
  end

  describe "normalize_importance/1" do
    test "clamps integers into 0..10" do
      assert MemoryHelpers.normalize_importance(-3) == 0
      assert MemoryHelpers.normalize_importance(4) == 4
      assert MemoryHelpers.normalize_importance(99) == 10
    end

    test "falls back to 5 for non-integers" do
      assert MemoryHelpers.normalize_importance(nil) == 5
      assert MemoryHelpers.normalize_importance("high") == 5
      assert MemoryHelpers.normalize_importance(3.5) == 5
    end
  end

  describe "document_matches_opts?/2" do
    test "matches when no filter is given" do
      assert MemoryHelpers.document_matches_opts?(%{}, [])
    end

    test "filters by normalized memory type" do
      data = %{"memory_type" => "code"}
      assert MemoryHelpers.document_matches_opts?(data, memory_type: :code)
      refute MemoryHelpers.document_matches_opts?(data, memory_type: :session)
    end

    test "filters by session id" do
      data = %{"session_id" => "s1"}
      assert MemoryHelpers.document_matches_opts?(data, session_id: "s1")
      refute MemoryHelpers.document_matches_opts?(data, session_id: "s2")
    end
  end

  describe "match_workspace?/2 and memory_forgotten?/1" do
    test "workspace filter" do
      data = %{"workspace_root" => "/w"}
      assert MemoryHelpers.match_workspace?(data, [])
      assert MemoryHelpers.match_workspace?(data, workspace_root: "/w")
      refute MemoryHelpers.match_workspace?(data, workspace_root: "/other")
    end

    test "forgotten only when a non-blank marker exists" do
      refute MemoryHelpers.memory_forgotten?(%{})
      refute MemoryHelpers.memory_forgotten?(%{"forgotten_at" => "   "})
      refute MemoryHelpers.memory_forgotten?(%{"forgotten_at" => 123})
      assert MemoryHelpers.memory_forgotten?(%{"forgotten_at" => "2026-01-01T00:00:00Z"})
    end
  end

  describe "incident_query?/1" do
    test "detects incident keywords" do
      assert MemoryHelpers.incident_query?(["fix", "parser"])
      assert MemoryHelpers.incident_query?(["timeout"])
      refute MemoryHelpers.incident_query?(["parser", "refactor"])
      refute MemoryHelpers.incident_query?([])
    end
  end

  describe "extract_session_id/1" do
    test "splits session keys" do
      assert MemoryHelpers.extract_session_id("session:abc:turn") == "abc"
      assert MemoryHelpers.extract_session_id("session:abc") == "abc"
    end

    test "defaults to unknown" do
      assert MemoryHelpers.extract_session_id("other:abc") == "unknown"
      assert MemoryHelpers.extract_session_id(nil) == "unknown"
    end
  end

  describe "build_structured_id/2 and build_pattern_key/2" do
    test "structured id embeds the prefix and date" do
      id = MemoryHelpers.build_structured_id("LRN", "content")
      date = Date.utc_today() |> Date.to_string() |> String.replace("-", "")
      assert id =~ ~r/^LRN-#{date}-[0-9A-F]{8}$/
    end

    test "structured ids are deterministic per content" do
      assert MemoryHelpers.build_structured_id("LRN", "same") ==
               MemoryHelpers.build_structured_id("LRN", "same")
    end

    test "pattern keys are 8 hex chars and content-dependent" do
      key = MemoryHelpers.build_pattern_key("bug", "nil crash")
      assert key =~ ~r/^[0-9A-F]{8}$/
      refute key == MemoryHelpers.build_pattern_key("bug", "other crash")
      refute key == MemoryHelpers.build_pattern_key("fix", "nil crash")
    end
  end

  describe "search_tokens/1" do
    test "lowercases, splits and drops one-character tokens" do
      assert MemoryHelpers.search_tokens("Fix The Parser_Bug a") == ["fix", "the", "parser_bug"]
    end

    test "accepts non-binary input" do
      assert MemoryHelpers.search_tokens(:abc) == ["abc"]
    end
  end

  describe "clamp_score/1" do
    test "clamps into 0.0..1.0" do
      assert MemoryHelpers.clamp_score(-1) == 0.0
      assert MemoryHelpers.clamp_score(0.5) == 0.5
      assert MemoryHelpers.clamp_score(7) == 1.0
    end

    test "returns 0.0 for non-numbers" do
      assert MemoryHelpers.clamp_score(nil) == 0.0
    end
  end

  describe "stringify_keys/1 and maybe_put/3" do
    test "stringifies keys without touching values" do
      assert MemoryHelpers.stringify_keys(%{:a => 1, "b" => 2}) == %{"a" => 1, "b" => 2}
    end

    test "maybe_put skips nil values" do
      assert MemoryHelpers.maybe_put(%{}, :a, nil) == %{}
      assert MemoryHelpers.maybe_put(%{}, :a, 1) == %{a: 1}
      assert MemoryHelpers.maybe_put(%{a: 1}, :a, 2) == %{a: 2}
    end
  end

  describe "build_citation/1" do
    test "formats single and ranged lines" do
      assert MemoryHelpers.build_citation(%{"path" => "a.ex", "line_start" => 3, "line_end" => 9}) ==
               "a.ex#L3-L9"

      assert MemoryHelpers.build_citation(%{"path" => "a.ex", "line_start" => 3}) == "a.ex#L3"
    end

    test "falls back to the bare source" do
      assert MemoryHelpers.build_citation(%{"path" => "a.ex"}) == "a.ex"
      assert MemoryHelpers.build_citation(%{}) == "memory"
    end
  end

  describe "document_result/2" do
    test "renders a hit from a node map with a data payload" do
      node = %{data: %{"content" => "body", "path" => "a.ex", "memory_type" => "code"}}

      scoring = %{
        score: 0.9,
        signal: :semantic,
        signal_score: 0.8,
        score_components: %{semantic: 0.8}
      }

      result = MemoryHelpers.document_result(node, scoring)

      assert result.role == "document"
      assert result.content == "body"
      assert result.source == "a.ex"
      assert result.citation == "a.ex"
      assert result.memory_type == "code"
      assert result.signals == [:semantic]
      assert result.forgotten? == false
    end

    test "defaults memory type and importance, and increments access count" do
      node = %{data: %{"content" => "x"}}
      scoring = %{score: 1.0, signal: :text, signal_score: 1.0, score_components: %{}}

      result = MemoryHelpers.document_result(node, scoring)

      assert result.memory_type == "reference"
      assert result.importance == 5
      assert result.access_count == 1
    end

    test "accepts a struct that exposes :data" do
      node = %FakeNode{data: %{"content" => "c", "forgotten_at" => "now"}}
      scoring = %{score: 0.1, signal: :text, signal_score: 0.1, score_components: %{}}

      assert MemoryHelpers.document_result(node, scoring).forgotten? == true
    end
  end
end
