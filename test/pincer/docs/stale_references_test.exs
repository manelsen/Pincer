defmodule Pincer.Docs.StaleReferencesTest do
  use ExUnit.Case, async: true

  @root Path.expand("../../..", __DIR__)

  defp read_doc!(relative_path) do
    @root
    |> Path.join(relative_path)
    |> File.read!()
  end

  describe "packages/pincer_telegram/README.md" do
    test "reflects extracted standalone package rather than pre-extraction scaffold" do
      content = read_doc!("packages/pincer_telegram/README.md")

      refute content =~ "pre-extraction scaffold"
      refute content =~ "lib/pincer/channels/telegram"
      assert content =~ "Pincer.Ports.Channel"
      assert content =~ "scripts/check_packages.exs"
    end
  end

  describe "plans/PRD-new-channels.md" do
    test "reflects implemented packages/pincer_* architecture rather than draft lib/pincer/channels/* paths" do
      content = read_doc!("plans/PRD-new-channels.md")

      refute content =~ "lib/pincer/channels/"
      refute content =~ "**Status**: Draft"
      assert content =~ "packages/pincer_feishu"
      assert content =~ "packages/pincer_line"
      assert content =~ "packages/pincer_dingtalk"
    end
  end

  describe "SPECS.md" do
    test "does not document dead core modules removed in CLEAN-001" do
      content = read_doc!("SPECS.md")

      refute content =~ "Pincer.Core.LLM.ModelRouter"
      refute content =~ "Pincer.Core.Session.CommandQueue"
      refute content =~ "Pincer.Core.Heartbeat.ContractEngine"
      refute content =~ "ModelRouter"
      refute content =~ "CommandQueue"
      refute content =~ "ContractEngine"
    end
  end

  describe "AGENTS.md" do
    test "does not reference removed boundary: [externals: or deleted core modules" do
      content = read_doc!("AGENTS.md")

      refute content =~ "boundary: [externals:"
      refute content =~ "ModelRouter"
      refute content =~ "CommandQueue"
      refute content =~ "ContractEngine"
      assert content =~ "check: [apps:"
    end
  end
end
