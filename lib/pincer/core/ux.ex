defmodule Pincer.Core.UX do
  @moduledoc """
  Core UX contract shared across channels.

  This module keeps user-facing command ergonomics in the core so adapters can
  render the same interaction model without becoming the source of truth.
  """

  @behaviour Pincer.Ports.UserMenu

  @type command :: %{name: String.t(), description: String.t()}
  @type shortcut_result :: {:ok, String.t()} | :error

  @commands [
    %{name: "menu", description: "Show command menu and shortcuts"},
    %{name: "status", description: "Show current session status"},
    %{name: "models", description: "Switch AI provider and model"},
    %{name: "kanban", description: "Show project kanban board"},
    %{name: "project", description: "Open project manager wizard"},
    %{name: "ping", description: "Health check"}
  ]

  @shortcut_routes %{
    "menu" => "/menu",
    "/menu" => "/menu",
    "status" => "/status",
    "/status" => "/status",
    "models" => "/models",
    "/models" => "/models",
    "kanban" => "/kanban",
    "/kanban" => "/kanban",
    "project" => "/project",
    "/project" => "/project",
    "projeto" => "/project",
    "/projeto" => "/project",
    "ping" => "/ping",
    "/ping" => "/ping",
    "help" => "/menu",
    "/help" => "/menu",
    "commands" => "/menu",
    "/commands" => "/menu"
  }

  @spec commands() :: [command()]
  def commands, do: @commands

  @spec help_text(atom()) :: String.t()
  def help_text(_channel \\ :generic) do
    """
    Command Menu
    /menu   - Open this menu
    /status - Show session status
    /models - Switch provider/model
    /kanban - Show session kanban board
    /project - Start/resume project manager wizard
    /ping   - Check if the bot is alive

    Accessibility note:
    - Use short, explicit commands.
    - Type menu, status, models, kanban, project or ping with or without /.
    - Menu button always opens /menu.
    """
    |> String.trim()
  end

  @spec resolve_shortcut(String.t()) :: shortcut_result()
  def resolve_shortcut(input) when is_binary(input) do
    normalized =
      input
      |> String.trim()
      |> String.downcase()

    cond do
      normalized == "" ->
        :error

      normalized == String.downcase(menu_button_label()) ->
        {:ok, "/menu"}

      true ->
        case Map.get(@shortcut_routes, normalized) do
          nil -> :error
          command -> {:ok, command}
        end
    end
  end

  def resolve_shortcut(_), do: :error

  @spec unknown_command_hint() :: String.t()
  def unknown_command_hint do
    "Use /menu, /status, /models, /kanban, /project or /ping."
  end

  @spec unknown_interaction_hint() :: String.t()
  def unknown_interaction_hint do
    "Unknown or expired menu action. Use /menu."
  end

  @spec menu_button_label() :: String.t()
  def menu_button_label, do: "Menu"
end
