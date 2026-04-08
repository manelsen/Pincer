defmodule PincerPorts do
  @moduledoc """
  Port behaviours and contracts for the Pincer AI agent framework.

  This package provides the core behaviour definitions that channel adapters
  (pincer_telegram, pincer_cli, etc.) implement. It has zero external
  dependencies — pure Elixir/OTP.

  ## Behaviours

  - `Pincer.Ports.Channel` — contract for bidirectional channel adapters
  """
end
