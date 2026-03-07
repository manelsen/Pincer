defmodule Pincer.Ports.Messaging do
  @moduledoc "Port for outbound messaging."
  alias Pincer.Infra.PubSub

  @callback deliver(String.t(), String.t()) :: :ok | {:error, term()}

  @doc "Dispatches a message to the appropriate adapter via PubSub."
  def deliver(session_id, message) do
    # Emit a global delivery event. Adapters are responsible for picking it up.
    PubSub.broadcast("system:delivery", {:deliver_message, session_id, message})
    :ok
  end
end
