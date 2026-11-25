defmodule PincerPorts do
  @moduledoc """
  Port behaviours and contracts for the Pincer AI agent framework.

  This package provides the contract definitions that channel adapters
  (pincer_telegram, pincer_cli, etc.), LLM provider packages, and the Pincer
  core share. It is a Boundary owner (`deps: []`) and every contract it exports
  lives under the `PincerPorts.*` namespace.

  ## Exported contracts

  - `PincerPorts.Structs.Usage` — normalized token usage accounting
  - `PincerPorts.Structs.IncomingMessage` — channel-agnostic inbound message
  - `PincerPorts.Session.Context` — resolved runtime context of a session
  - `PincerPorts.LLM.Provider` — behaviour implemented by LLM provider adapters
  - `PincerPorts.LLM.RawResponseLogger` — shared raw provider payload logging
  - `PincerPorts.Channel` — contract for bidirectional channel adapters
  - `PincerPorts.ChannelPolicy` — access and approval rules for channels
  - `PincerPorts.Project` — project wizard as seen from a channel
  - `PincerPorts.Session` — driving agent sessions from a channel
  - `PincerPorts.Streaming` — streaming and status-presentation policies
  - `PincerPorts.UX` — channel-facing user experience vocabulary
  """

  use Boundary,
    deps: [],
    exports: [
      Structs.Usage,
      Structs.IncomingMessage,
      Session.Context,
      LLM.Provider,
      LLM.RawResponseLogger,
      Channel,
      ChannelPolicy,
      Project,
      Session,
      Streaming,
      UX
    ]
end
