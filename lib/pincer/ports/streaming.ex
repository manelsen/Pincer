defmodule Pincer.Ports.Streaming do
  @moduledoc """
  Transition delegate for `PincerPorts.Streaming`.

  The contract now lives in the `pincer_ports` package under the
  `PincerPorts.*` namespace. This module only forwards every public function
  so root callers keep working while they migrate; new code should call
  `PincerPorts.Streaming` directly.
  """

  for {name, arity} <- PincerPorts.Streaming.__info__(:functions) do
    args = Macro.generate_arguments(arity, __MODULE__)

    @doc false
    defdelegate unquote(name)(unquote_splicing(args)), to: PincerPorts.Streaming
  end
end
