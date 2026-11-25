defmodule Pincer.Ports.UX do
  @moduledoc """
  Port for the channel-facing user experience vocabulary.

  Channels render menus, resolve typed shortcuts and label buttons. Those
  strings and rules belong to the agent runtime, not to any transport, so the
  adapter layer asks this port instead of importing `Pincer.Core.UX` and
  friends directly. Core registers the implementation at boot.

  ## Example

      case Pincer.Ports.UX.resolve_shortcut("model") do
        {:ok, command} -> run(command)
        :error -> treat_as_message()
      end
  """

  @type channel :: atom()
  @type command :: String.t()
  @type keyboard :: term()

  @callback commands() :: [command()]
  @callback help_text(channel()) :: String.t()
  @callback menu_button_label() :: String.t()
  @callback unknown_command_hint() :: String.t()
  @callback unknown_interaction_hint() :: String.t()
  @callback resolve_shortcut(String.t() | term()) :: {:ok, command()} | :error
  @callback registerable_commands(channel(), [command()]) :: [command()]
  @callback build_keyboard(
              channel(),
              String.t(),
              [String.t()],
              non_neg_integer(),
              String.t() | nil
            ) ::
              keyboard()

  @doc false
  def adapter do
    case Application.fetch_env(:pincer, :ux_adapter) do
      {:ok, mod} when is_atom(mod) and not is_nil(mod) and not is_boolean(mod) ->
        mod

      {:ok, invalid} ->
        raise ArgumentError,
              "invalid :ux_adapter configuration for :pincer: #{inspect(invalid)}"

      :error ->
        raise ArgumentError,
              "missing :ux_adapter configuration for :pincer (configure config :pincer, :ux_adapter, ...)"
    end
  end

  @spec commands() :: [command()]
  def commands, do: adapter().commands()

  def help_text(channel \\ :generic), do: adapter().help_text(channel)
  def menu_button_label, do: adapter().menu_button_label()
  def unknown_command_hint, do: adapter().unknown_command_hint()
  def unknown_interaction_hint, do: adapter().unknown_interaction_hint()
  def resolve_shortcut(input), do: adapter().resolve_shortcut(input)

  def registerable_commands(channel, commands),
    do: adapter().registerable_commands(channel, commands)

  def build_keyboard(channel, provider_id, models, page, current_model),
    do: adapter().build_keyboard(channel, provider_id, models, page, current_model)
end
