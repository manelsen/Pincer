defmodule Pincer.Ports do
  @moduledoc "Neutral Ports layer for Hexagonal Architecture."
  use Boundary,
    type: :strict,
    deps: [Pincer.Infra, PincerPorts],
    check: [aliases: true],
    exports: [
      Messaging,
      Storage,
      LLM,
      MediaUnderstanding,
      ToolRegistry,
      CapabilityDiscovery,
      Onboarding,
      UserMenu,
      Tool,
      Cron,
      Hook,
      Sandbox,
      Channel,
      ChannelPolicy,
      Project,
      Session,
      Streaming,
      UX
    ]
end
