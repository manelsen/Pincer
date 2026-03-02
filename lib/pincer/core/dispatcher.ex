defmodule Pincer.Core.Dispatcher do
  @moduledoc """
  Central Domain Dispatcher.
  Routes outbound messages via the Messaging Port.
  Completely decoupled from specific channel adapters.
  """
  alias Pincer.Ports.Messaging

  @doc "Dispatches a message to the outbound port."
  def dispatch(session_id, message) do
    Messaging.deliver(session_id, message)
  end
end
