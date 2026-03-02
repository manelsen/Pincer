defmodule Pincer.Utils.MessageSplitterTest do
  use ExUnit.Case
  alias Pincer.Utils.MessageSplitter

  describe "split/2" do
    test "returns text as-is if within limit" do
      text = "Short message"
      assert MessageSplitter.split(text, 100) == ["Short message"]
    end

    test "splits by lines when possible" do
      text = "Line 1\nLine 2\nLine 3"
      # Limit small enough to force split, but large enough for individual lines
      assert MessageSplitter.split(text, 7) == ["Line 1", "Line 2", "Line 3"]
    end

    test "accumulates lines up to limit" do
      text = "Line 1\nLine 2\nLine 3"
      # Limit allows 2 lines (6+1+6 = 13 chars)
      assert MessageSplitter.split(text, 13) == ["Line 1\nLine 2", "Line 3"]
    end

    test "splits huge lines by words" do
      text = "Word1 Word2 Word3"
      # Limit forces word split (5 chars max)
      assert MessageSplitter.split(text, 5) == ["Word1", "Word2", "Word3"]
    end

    test "hard splits massive words" do
      text = "ABCDEFGHIJ"
      # Limit 5
      assert MessageSplitter.split(text, 5) == ["ABCDE", "FGHIJ"]
    end

    test "preserves paragraphs (double newlines)" do
      text = "Para 1\n\nPara 2"
      # Split should respect the empty line as a separator if it fits?
      # Our logic splits by \n. So ["Para 1", "", "Para 2"].
      # Accumulator will join with \n.
      # "Para 1" + \n + "" = "Para 1\n"
      # "Para 1\n" + \n + "Para 2" = "Para 1\n\nPara 2".
      # If limit allows, it stays together.
      assert MessageSplitter.split(text, 50) == ["Para 1\n\nPara 2"]
    end
  end
end
