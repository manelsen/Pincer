defmodule Pincer.Ports.UX do
  @moduledoc """
  Transition delegate for `PincerPorts.UX`.

  The contract now lives in the `pincer_ports` package under the
  `PincerPorts.*` namespace. This module only forwards every public function
  so root callers keep working while they migrate; new code should call
  `PincerPorts.UX` directly.
  """

  for {name, arity} <- PincerPorts.UX.__info__(:functions) do
    args = Macro.generate_arguments(arity, __MODULE__)

    @doc false
    defdelegate unquote(name)(unquote_splicing(args)), to: PincerPorts.UX
  end
end
