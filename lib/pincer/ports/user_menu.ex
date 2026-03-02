defmodule Pincer.Ports.UserMenu do
  @moduledoc """
  Port for channel-agnostic menu/command UX contracts.

  Channels render this contract, but do not define it.
  """

  @type command :: %{name: String.t(), description: String.t()}

  @callback commands() :: [command()]
  @callback help_text(channel :: atom()) :: String.t()
  @callback resolve_shortcut(input :: String.t()) :: {:ok, String.t()} | :error
  @callback unknown_command_hint() :: String.t()
  @callback unknown_interaction_hint() :: String.t()
  @callback menu_button_label() :: String.t()
end
