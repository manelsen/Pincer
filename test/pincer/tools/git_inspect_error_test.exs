defmodule Pincer.Adapters.Tools.GitInspectErrorTest do
  use ExUnit.Case, async: true

  alias Pincer.Adapters.Tools.GitInspectError

  test "formats not-a-repository errors tersely" do
    assert GitInspectError.format(
             "fatal: not a git repository (or any of the parent directories): .git"
           ) ==
             "Path is not a Git repository."
  end

  test "formats missing pathspec tersely" do
    assert GitInspectError.format(
             "fatal: pathspec 'missing.txt' did not match any file(s) known to git"
           ) ==
             "Git path not found: missing.txt"
  end

  test "formats ambiguous argument tersely" do
    assert GitInspectError.format(
             "fatal: ambiguous argument 'ghost': unknown revision or path not in the working tree."
           ) ==
             "Git reference or path not found: ghost"
  end

  test "falls back to trimmed stderr" do
    assert GitInspectError.format("fatal: boom\n") == "fatal: boom"
    assert GitInspectError.format("") == "Git command failed."
  end
end
