defmodule Pincer.Core.UX do
  @moduledoc """
  Core UX contract shared across channels.

  This module keeps user-facing command ergonomics in the core so adapters can
  render the same interaction model without becoming the source of truth.
  """

  @behaviour Pincer.Core.Ports.UserMenu

  @type command :: %{name: String.t(), description: String.t()}

  @commands [
    %{name: "menu", description: "Show command menu and shortcuts"},
    %{name: "status", description: "Show current session status"},
    %{name: "models", description: "Switch AI provider and model"},
    %{name: "ping", description: "Health check"}
  ]

  @spec commands() :: [command()]
  def commands, do: @commands

  @spec help_text(atom()) :: String.t()
  def help_text(_channel \\ :generic) do
    """
    Command Menu
    ------------
    /menu   - Open this menu
    /status - Show session status
    /models - Switch provider/model
    /ping   - Check if the bot is alive

    Accessibility note:
    - Use short, explicit commands.
    - Menu is always available via /menu.
    """
    |> String.trim()
  end

  @spec unknown_command_hint() :: String.t()
  def unknown_command_hint do
    "Try /menu, /ping, /models or /status."
  end

  @spec unknown_interaction_hint() :: String.t()
  def unknown_interaction_hint do
    "Menu action unknown or expired. Use /menu to open it again."
  end

  @spec menu_button_label() :: String.t()
  def menu_button_label, do: "Menu"
end
