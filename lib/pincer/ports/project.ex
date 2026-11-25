defmodule Pincer.Ports.Project do
  @moduledoc """
  Transition delegate for `PincerPorts.Project`.

  The contract now lives in the `pincer_ports` package under the
  `PincerPorts.*` namespace. This module only forwards every public function
  so root callers keep working while they migrate; new code should call
  `PincerPorts.Project` directly.
  """

  for {name, arity} <- PincerPorts.Project.__info__(:functions) do
    args = Macro.generate_arguments(arity, __MODULE__)

    @doc false
    defdelegate unquote(name)(unquote_splicing(args)), to: PincerPorts.Project
  end
end
