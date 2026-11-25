defmodule Pincer.Core.UX.AdapterTest do
  # The port-dispatch block swaps the global `:ux_adapter` that every channel
  # reads, so this module must not run alongside others.
  use ExUnit.Case, async: false

  alias Pincer.Core.UX.Adapter

  defmodule Stub do
    @behaviour PincerPorts.UX

    def commands, do: {:commands}
    def help_text(channel), do: {:help_text, channel}
    def menu_button_label, do: {:menu_button_label}
    def unknown_command_hint, do: {:unknown_command_hint}
    def unknown_interaction_hint, do: {:unknown_interaction_hint}
    def resolve_shortcut(input), do: {:resolve_shortcut, input}
    def registerable_commands(channel, commands), do: {:registerable_commands, channel, commands}

    def build_keyboard(channel, provider_id, models, page, current_model),
      do: {:build_keyboard, channel, provider_id, models, page, current_model}
  end

  test "implements the UX behaviour and its callbacks" do
    behaviours =
      Adapter.module_info(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    assert PincerPorts.UX in behaviours

    for {fun, arity} <- PincerPorts.UX.behaviour_info(:callbacks) do
      assert function_exported?(Adapter, fun, arity),
             "Adapter does not implement #{fun}/#{arity}"
    end
  end

  test "the test double covers every port callback" do
    for {fun, arity} <- PincerPorts.UX.behaviour_info(:callbacks) do
      assert function_exported?(Stub, fun, arity),
             "Stub does not implement #{fun}/#{arity} - update it with the port"
    end
  end

  test "menu_button_label/0 returns the shared label used by channels" do
    assert Adapter.menu_button_label() == "Menu"
  end

  test "resolve_shortcut/1 maps known words to slash commands and rejects the rest" do
    assert Adapter.resolve_shortcut("menu") == {:ok, "/menu"}
    assert Adapter.resolve_shortcut(123) == :error
  end

  test "commands/0 returns command entries with a name and a description" do
    commands = Adapter.commands()

    assert is_list(commands)
    assert commands != []

    assert Enum.all?(commands, fn command ->
             is_map(command) and is_binary(command.name) and is_binary(command.description)
           end)
  end

  test "build_keyboard/5 returns keyboard rows as lists of button maps" do
    keyboard = Adapter.build_keyboard(:telegram, "provider", ["model"], 1, nil)

    assert is_list(keyboard)
    assert keyboard != []

    assert Enum.all?(keyboard, fn row ->
             is_list(row) and row != [] and Enum.all?(row, &is_map/1)
           end)
  end

  describe "port dispatch" do
    setup do
      previous = Application.get_env(:pincer, :ux_adapter)
      Application.put_env(:pincer, :ux_adapter, Stub)
      on_exit(fn -> restore(previous) end)
      :ok
    end

    test "routes every operation through the configured adapter" do
      assert Pincer.Ports.UX.commands() == {:commands}
      assert Pincer.Ports.UX.help_text(:telegram) == {:help_text, :telegram}
      assert Pincer.Ports.UX.menu_button_label() == {:menu_button_label}
      assert Pincer.Ports.UX.unknown_command_hint() == {:unknown_command_hint}
      assert Pincer.Ports.UX.unknown_interaction_hint() == {:unknown_interaction_hint}
      assert Pincer.Ports.UX.resolve_shortcut("menu") == {:resolve_shortcut, "menu"}

      assert Pincer.Ports.UX.registerable_commands(:telegram, ["menu"]) ==
               {:registerable_commands, :telegram, ["menu"]}

      assert Pincer.Ports.UX.build_keyboard(:telegram, "p", ["m"], 1, nil) ==
               {:build_keyboard, :telegram, "p", ["m"], 1, nil}
    end
  end

  defp restore(nil), do: Application.delete_env(:pincer, :ux_adapter)
  defp restore(value), do: Application.put_env(:pincer, :ux_adapter, value)
end
