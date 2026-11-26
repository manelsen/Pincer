defmodule Pincer.Utils.ANSI do
  @moduledoc """
  Centralized terminal ANSI styling helpers.

  Wraps `IO.ANSI` sequences so CLI frontends, Mix tasks, and log formatters
  share a consistent color palette and respect `IO.ANSI.enabled?/0` by default
  unless explicitly overridden via `enabled?: true | false`.
  """

  @type color ::
          :black
          | :red
          | :green
          | :yellow
          | :blue
          | :magenta
          | :cyan
          | :white
          | :gray
          | :light_black

  @color_map %{
    black: :black,
    red: :red,
    green: :green,
    yellow: :yellow,
    blue: :blue,
    magenta: :magenta,
    cyan: :cyan,
    white: :white,
    gray: :light_black,
    light_black: :light_black
  }

  @doc """
  Wraps `text` with the ANSI color sequence for `color` followed by a reset.

  Emits ANSI sequences when `IO.ANSI.enabled?/0` is true unless overridden with
  the `:enabled?` option.
  """
  @spec colorize(iodata(), color(), keyword()) :: String.t()
  def colorize(text, color, opts \\ []) when is_atom(color) and is_list(opts) do
    enabled? = Keyword.get(opts, :enabled?, IO.ANSI.enabled?())
    ansi_color = Map.fetch!(@color_map, color)

    [ansi_color, text]
    |> IO.ANSI.format(enabled?)
    |> IO.iodata_to_binary()
  end

  @doc "Styles `text` in green."
  @spec green(iodata(), keyword()) :: String.t()
  def green(text, opts \\ []), do: colorize(text, :green, opts)

  @doc "Styles `text` in yellow."
  @spec yellow(iodata(), keyword()) :: String.t()
  def yellow(text, opts \\ []), do: colorize(text, :yellow, opts)

  @doc "Styles `text` in blue."
  @spec blue(iodata(), keyword()) :: String.t()
  def blue(text, opts \\ []), do: colorize(text, :blue, opts)

  @doc "Styles `text` in red."
  @spec red(iodata(), keyword()) :: String.t()
  def red(text, opts \\ []), do: colorize(text, :red, opts)

  @doc "Styles `text` in cyan."
  @spec cyan(iodata(), keyword()) :: String.t()
  def cyan(text, opts \\ []), do: colorize(text, :cyan, opts)

  @doc "Styles `text` in magenta."
  @spec magenta(iodata(), keyword()) :: String.t()
  def magenta(text, opts \\ []), do: colorize(text, :magenta, opts)

  @doc "Styles `text` in gray (`:light_black`)."
  @spec gray(iodata(), keyword()) :: String.t()
  def gray(text, opts \\ []), do: colorize(text, :gray, opts)

  @doc "Styles `text` as a success/ok message (green)."
  @spec ok(iodata(), keyword()) :: String.t()
  def ok(text, opts \\ []), do: colorize(text, :green, opts)

  @doc "Styles `text` as a warning message (yellow)."
  @spec warn(iodata(), keyword()) :: String.t()
  def warn(text, opts \\ []), do: colorize(text, :yellow, opts)

  @doc "Styles `text` as an informational message (blue)."
  @spec info(iodata(), keyword()) :: String.t()
  def info(text, opts \\ []), do: colorize(text, :blue, opts)

  @doc "Styles `text` as an error message (red)."
  @spec error(iodata(), keyword()) :: String.t()
  def error(text, opts \\ []), do: colorize(text, :red, opts)

  @doc "Styles `text` as a debug message (magenta)."
  @spec debug(iodata(), keyword()) :: String.t()
  def debug(text, opts \\ []), do: colorize(text, :magenta, opts)

  @doc "Styles `text` as muted/secondary text (gray)."
  @spec muted(iodata(), keyword()) :: String.t()
  def muted(text, opts \\ []), do: colorize(text, :gray, opts)

  @doc "Returns the clear-screen and cursor-home sequence when ANSI is enabled."
  @spec clear_screen(keyword()) :: String.t()
  def clear_screen(opts \\ []) when is_list(opts) do
    if Keyword.get(opts, :enabled?, IO.ANSI.enabled?()) do
      IO.ANSI.clear() <> IO.ANSI.home()
    else
      ""
    end
  end
end
