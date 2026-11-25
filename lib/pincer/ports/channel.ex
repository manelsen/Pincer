defmodule Pincer.Ports.Channel do
  @moduledoc """
  Transition forwarder for `PincerPorts.Channel`.

  The channel contract now lives in the `pincer_ports` package under the
  `PincerPorts.*` namespace. `use Pincer.Ports.Channel` simply expands to
  `use PincerPorts.Channel` so existing callers keep working while they
  migrate; new code should use `PincerPorts.Channel` directly.
  """

  @doc false
  defmacro __using__(opts) do
    quote do
      use PincerPorts.Channel, unquote(opts)
    end
  end
end
