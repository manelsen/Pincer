defmodule Pincer.Ports do
  @moduledoc "Neutral Ports layer for Hexagonal Architecture."
  use Boundary, 
    deps: [Pincer.Infra],
    exports: [
      Messaging,
      Storage,
      LLM,
      ToolRegistry,
      CapabilityDiscovery,
      Onboarding,
      UserMenu,
      Channel,
      Tool,
      Cron
    ]
end
