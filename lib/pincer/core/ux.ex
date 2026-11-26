defmodule Pincer.Core.UX do
  @moduledoc """
  Core UX contract shared across channels.

  This module keeps user-facing command ergonomics in the core so adapters can
  render the same interaction model without becoming the source of truth.
  """
  use Boundary,
    deps: [Pincer.Core, Pincer.Ports],
    exports: [Adapter, ChannelInteractionPolicy, MenuPolicy, ModelKeyboard]

  @type command :: %{name: String.t(), description: String.t()}
  @type shortcut_result :: {:ok, String.t()} | :error

  @command_catalog [
    %{
      name: "menu",
      description: "Show command menu and shortcuts",
      route: "/menu",
      aliases: ["help", "commands"]
    },
    %{
      name: "status",
      description: "Show current session status",
      route: "/status",
      aliases: []
    },
    %{
      name: "models",
      description: "Switch AI provider and model",
      route: "/models",
      aliases: []
    },
    %{
      name: "kanban",
      description: "Show project kanban board",
      route: "/kanban",
      aliases: []
    },
    %{
      name: "project",
      description: "Open project manager wizard",
      route: "/project",
      aliases: ["projeto"]
    },
    %{
      name: "ping",
      description: "Health check",
      route: "/ping",
      aliases: []
    },
    %{
      name: "new",
      description: "Reset the current session",
      route: "/new",
      aliases: []
    },
    %{
      name: "reset",
      description: "Alias for /new",
      route: "/new",
      aliases: []
    },
    %{
      name: "model",
      description: "Switch model: /model <provider/model>",
      route: "/model",
      aliases: []
    },
    %{
      name: "think",
      description: "Thinking level: /think off|low|medium|high",
      route: "/think",
      aliases: []
    },
    %{
      name: "reasoning",
      description: "Show reasoning: /reasoning on|off",
      route: "/reasoning",
      aliases: []
    }
  ]

  @commands Enum.map(@command_catalog, &%{name: &1.name, description: &1.description})

  @shortcut_routes Map.new(
                     Enum.flat_map(@command_catalog, fn %{
                                                          name: name,
                                                          route: route,
                                                          aliases: aliases
                                                        } ->
                       Enum.flat_map([name | aliases], fn trigger ->
                         [{trigger, route}, {"/#{trigger}", route}]
                       end)
                     end)
                   )

  @max_name_width Enum.reduce(@command_catalog, 0, fn %{name: name}, acc ->
                    max(acc, String.length(name))
                  end)

  @help_text (
               command_lines =
                 Enum.map(@command_catalog, fn %{name: name, description: description} ->
                   "/#{String.pad_trailing(name, @max_name_width)} - #{description}"
                 end)

               shortcut_names = Enum.map_join(@command_catalog, ", ", & &1.name)

               (["Command Menu" | command_lines] ++
                  [
                    "",
                    "Accessibility note:",
                    "- Use short, explicit commands.",
                    "- Type #{shortcut_names} with or without /.",
                    "- Menu button always opens /menu."
                  ])
               |> Enum.join("\n")
             )

  @doc "Returns the list of available commands with descriptions."
  @spec commands() :: [command()]
  def commands, do: @commands

  @doc "Returns the formatted help text for a given channel."
  @spec help_text(atom()) :: String.t()
  def help_text(_channel \\ :generic), do: @help_text

  @doc """
  Resolves a user's text input to a known shortcut command.

  Returns `{:ok, command}` if recognized, `:error` otherwise.
  """
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

  @doc "Returns a hint message for unrecognized slash commands."
  @spec unknown_command_hint() :: String.t()
  def unknown_command_hint do
    "Use /menu, /status, /models, /kanban, /project or /ping."
  end

  @doc "Returns a hint message for unknown or expired menu interactions."
  @spec unknown_interaction_hint() :: String.t()
  def unknown_interaction_hint do
    "Unknown or expired menu action. Use /menu."
  end

  @doc "Returns the label used for the persistent menu button in channel adapters."
  @spec menu_button_label() :: String.t()
  def menu_button_label, do: "Menu"
end
