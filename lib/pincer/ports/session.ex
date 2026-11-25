defmodule Pincer.Ports.Session do
  @moduledoc """
  Transition delegate for `PincerPorts.Session`.

  The contract now lives in the `pincer_ports` package under the
  `PincerPorts.*` namespace. This module only forwards every public function
  so root callers keep working while they migrate; new code should call
  `PincerPorts.Session` directly.
  """

  for {name, arity} <- PincerPorts.Session.__info__(:functions) do
    args = Macro.generate_arguments(arity, __MODULE__)

    @doc false
    defdelegate unquote(name)(unquote_splicing(args)), to: PincerPorts.Session
  end
end
