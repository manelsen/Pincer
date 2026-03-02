defmodule Pincer.Core.UX.MenuPolicyTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.UX
  alias Pincer.Core.UX.MenuPolicy

  describe "registerable_commands/2" do
    test "builds Telegram payload from core UX commands" do
      result = MenuPolicy.registerable_commands(:telegram, UX.commands())

      assert result.issues == []
      assert result.dropped_count == 0

      assert Enum.map(result.commands, & &1.command) == [
               "menu",
               "status",
               "models",
               "kanban",
               "project",
               "ping"
             ]
    end

    test "applies validation and dedupe for Telegram" do
      result =
        MenuPolicy.registerable_commands(:telegram, [
          %{name: "Menu", description: "Open menu"},
          %{name: "menu", description: "duplicate"},
          %{name: "build-status", description: "invalid on telegram"},
          %{name: "ok_1", description: "   "},
          %{name: "good", description: "Good command"}
        ])

      assert Enum.map(result.commands, & &1.command) == ["menu", "good"]
      assert result.dropped_count == 3
      assert Enum.any?(result.issues, &String.contains?(&1, "duplicate"))
      assert Enum.any?(result.issues, &String.contains?(&1, "invalid"))
      assert Enum.any?(result.issues, &String.contains?(&1, "description"))
    end

    test "enforces channel cap for Discord" do
      commands =
        Enum.map(1..105, fn n ->
          %{name: "cmd_#{n}", description: "Command #{n}"}
        end)

      result = MenuPolicy.registerable_commands(:discord, commands)

      assert length(result.commands) == 100
      assert result.dropped_count == 5
      assert Enum.any?(result.issues, &String.contains?(&1, "limit"))
    end

    test "allows hyphen for Discord but not for Telegram" do
      discord =
        MenuPolicy.registerable_commands(:discord, [%{name: "build-status", description: "ok"}])

      telegram =
        MenuPolicy.registerable_commands(:telegram, [%{name: "build-status", description: "no"}])

      assert Enum.map(discord.commands, & &1.name) == ["build-status"]
      assert telegram.commands == []
    end
  end
end
