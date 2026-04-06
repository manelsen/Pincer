defmodule Pincer.Core.AlignmentIntegrityTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.AlignmentIntegrity

  @test_dir "tmp/test_alignment_#{System.unique_integer([:positive])}"

  setup do
    pincer_dir = Path.join(@test_dir, ".pincer")
    File.mkdir_p!(pincer_dir)

    File.write!(Path.join(pincer_dir, "IDENTITY.md"), "# TestBot\n")
    File.write!(Path.join(pincer_dir, "SOUL.md"), "## Core Truths\n1. Be helpful.\n")

    on_exit(fn -> File.rm_rf!(@test_dir) end)

    %{workspace: @test_dir, pincer_dir: pincer_dir}
  end

  describe "protected_files/1" do
    test "returns paths for existing protected files", %{workspace: ws} do
      files = AlignmentIntegrity.protected_files(ws)
      names = Enum.map(files, fn {name, _path} -> name end)

      assert "IDENTITY.md" in names
      assert "SOUL.md" in names
    end

    test "skips files that don't exist", %{workspace: ws, pincer_dir: pd} do
      File.rm!(Path.join(pd, "SOUL.md"))
      files = AlignmentIntegrity.protected_files(ws)
      names = Enum.map(files, fn {name, _path} -> name end)

      assert "IDENTITY.md" in names
      refute "SOUL.md" in names
    end
  end

  describe "snapshot!/1" do
    test "creates integrity file with SHA-256 hashes", %{workspace: ws, pincer_dir: pd} do
      :ok = AlignmentIntegrity.snapshot!(ws)

      integrity_path = Path.join(pd, ".alignment-integrity.json")
      assert File.exists?(integrity_path)

      {:ok, content} = File.read(integrity_path)
      {:ok, data} = Jason.decode(content)

      assert is_binary(data["IDENTITY.md"])
      assert is_binary(data["SOUL.md"])
      assert byte_size(data["IDENTITY.md"]) == 64
    end
  end

  describe "verify/1" do
    test "returns :ok when files are unchanged", %{workspace: ws} do
      :ok = AlignmentIntegrity.snapshot!(ws)
      assert {:ok, []} = AlignmentIntegrity.verify(ws)
    end

    test "detects tampered file", %{workspace: ws, pincer_dir: pd} do
      :ok = AlignmentIntegrity.snapshot!(ws)

      # Tamper with SOUL.md
      File.write!(Path.join(pd, "SOUL.md"), "## Hacked\n")

      assert {:ok, violations} = AlignmentIntegrity.verify(ws)
      assert length(violations) == 1
      assert %{file: "SOUL.md", status: :tampered} = hd(violations)
    end

    test "detects deleted file", %{workspace: ws, pincer_dir: pd} do
      :ok = AlignmentIntegrity.snapshot!(ws)

      File.rm!(Path.join(pd, "IDENTITY.md"))

      assert {:ok, violations} = AlignmentIntegrity.verify(ws)
      assert length(violations) == 1
      assert %{file: "IDENTITY.md", status: :missing} = hd(violations)
    end

    test "returns :no_snapshot when integrity file doesn't exist", %{workspace: ws} do
      assert {:error, :no_snapshot} = AlignmentIntegrity.verify(ws)
    end

    test "ignores new files not in original snapshot", %{workspace: ws, pincer_dir: pd} do
      :ok = AlignmentIntegrity.snapshot!(ws)

      # Add a new file (STYLE.md)
      File.write!(Path.join(pd, "STYLE.md"), "casual tone")

      assert {:ok, []} = AlignmentIntegrity.verify(ws)
    end
  end
end
