defmodule Pincer.Ports.Messaging do
  @moduledoc "Compatibility entry point for session delivery through `PincerPorts.Messaging`."

  @callback deliver(String.t(), String.t()) :: :ok | {:error, term()}

  @doc "Dispatches a message to the session's channel."
  defdelegate deliver(session_id, message), to: PincerPorts.Messaging
end
