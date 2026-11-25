defmodule Pincer.Core.UX.Adapter do
  @moduledoc """
  Implements `PincerPorts.UX` on top of `Pincer.Core.UX` and its menu modules.

  This is the only place that knows which Core modules own the UX vocabulary,
  so channel packages can depend on the port alone.
  """

  @behaviour PincerPorts.UX

  alias Pincer.Core.UX
  alias Pincer.Core.UX.{MenuPolicy, ModelKeyboard}

  @impl true
  def commands, do: UX.commands()

  @impl true
  def help_text(channel), do: UX.help_text(channel)

  @impl true
  def menu_button_label, do: UX.menu_button_label()

  @impl true
  def unknown_command_hint, do: UX.unknown_command_hint()

  @impl true
  def unknown_interaction_hint, do: UX.unknown_interaction_hint()

  @impl true
  def resolve_shortcut(input), do: UX.resolve_shortcut(input)

  @impl true
  def registerable_commands(channel, commands),
    do: MenuPolicy.registerable_commands(channel, commands)

  @impl true
  def build_keyboard(channel, provider_id, models, page, current_model),
    do: ModelKeyboard.build_keyboard(channel, provider_id, models, page, current_model)
end
