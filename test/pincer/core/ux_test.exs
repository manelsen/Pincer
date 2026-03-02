defmodule Pincer.Core.UXTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.UX

  test "commands/0 includes menu baseline commands" do
    names = UX.commands() |> Enum.map(& &1.name)

    assert "menu" in names
    assert "status" in names
    assert "models" in names
    assert "ping" in names
  end

  test "help_text/1 is screen-reader-friendly and explicit" do
    text = UX.help_text(:telegram)

    assert text =~ "Command Menu"
    assert text =~ "/menu"
    assert text =~ "/status"
    assert text =~ "/models"
    assert text =~ "/ping"
  end

  test "unknown_command_hint/0 points users to menu" do
    assert UX.unknown_command_hint() =~ "/menu"
  end

  test "unknown_interaction_hint/0 points users to menu" do
    assert UX.unknown_interaction_hint() =~ "/menu"
  end
end
