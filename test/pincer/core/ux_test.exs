defmodule Pincer.Core.UXTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.UX

  test "commands/0 includes menu baseline commands" do
    names = UX.commands() |> Enum.map(& &1.name)

    assert "menu" in names
    assert "status" in names
    assert "models" in names
    assert "kanban" in names
    assert "project" in names
    assert "ping" in names
  end

  test "help_text/1 is screen-reader-friendly and includes every catalog command" do
    text = UX.help_text(:telegram)

    assert text =~ "Command Menu"
    assert text =~ "with or without /"

    for %{name: name, description: description} <- UX.commands() do
      assert text =~ "/#{name}"
      assert text =~ description
    end

    assert text =~ "/new"
    assert text =~ "/reset"
    assert text =~ "/model"
    assert text =~ "/think"
    assert text =~ "/reasoning"
  end

  test "unknown_command_hint/0 points users to menu" do
    assert UX.unknown_command_hint() =~ "/menu"
    assert String.length(UX.unknown_command_hint()) <= 80
  end

  test "unknown_interaction_hint/0 points users to menu" do
    assert UX.unknown_interaction_hint() =~ "/menu"
    assert String.length(UX.unknown_interaction_hint()) <= 80
  end

  test "resolve_shortcut/1 accepts all catalog commands and aliases with and without slash" do
    assert {:ok, "/menu"} = UX.resolve_shortcut("menu")
    assert {:ok, "/menu"} = UX.resolve_shortcut("/menu")
    assert {:ok, "/status"} = UX.resolve_shortcut("status")
    assert {:ok, "/models"} = UX.resolve_shortcut("/models")
    assert {:ok, "/kanban"} = UX.resolve_shortcut("kanban")
    assert {:ok, "/kanban"} = UX.resolve_shortcut("/kanban")
    assert {:ok, "/project"} = UX.resolve_shortcut("project")
    assert {:ok, "/project"} = UX.resolve_shortcut("/project")
    assert {:ok, "/project"} = UX.resolve_shortcut("projeto")
    assert {:ok, "/project"} = UX.resolve_shortcut("/projeto")
    assert {:ok, "/ping"} = UX.resolve_shortcut("ping")
    assert {:ok, "/new"} = UX.resolve_shortcut("new")
    assert {:ok, "/new"} = UX.resolve_shortcut("/new")
    assert {:ok, "/new"} = UX.resolve_shortcut("reset")
    assert {:ok, "/new"} = UX.resolve_shortcut("/reset")
    assert {:ok, "/model"} = UX.resolve_shortcut("model")
    assert {:ok, "/model"} = UX.resolve_shortcut("/model")
    assert {:ok, "/think"} = UX.resolve_shortcut("think")
    assert {:ok, "/think"} = UX.resolve_shortcut("/think")
    assert {:ok, "/reasoning"} = UX.resolve_shortcut("reasoning")
    assert {:ok, "/reasoning"} = UX.resolve_shortcut("/reasoning")

    for %{name: name} <- UX.commands() do
      assert {:ok, _route} = UX.resolve_shortcut(name)
      assert {:ok, _route} = UX.resolve_shortcut("/#{name}")
    end
  end

  test "resolve_shortcut/1 keeps compatibility for help aliases and Menu label" do
    assert {:ok, "/menu"} = UX.resolve_shortcut("/help")
    assert {:ok, "/menu"} = UX.resolve_shortcut("/commands")
    assert {:ok, "/menu"} = UX.resolve_shortcut("Menu")
  end

  test "resolve_shortcut/1 rejects free-form text" do
    assert :error = UX.resolve_shortcut("")
    assert :error = UX.resolve_shortcut("hello there")
    assert :error = UX.resolve_shortcut("status please")
  end
end
