defmodule Pincer.Adapters.Tools do
  @moduledoc "Tool adapters."
  use Boundary,
    type: :strict,
    deps: [
      Pincer.Adapters,
      Pincer.Core,
      Pincer.Ports,
      Pincer.Infra,
      Pincer.Utils,
      PincerPorts,
      Jason,
      Logger,
      Req
    ],
    exports: [
      SafeShell,
      FileSystem,
      Web,
      GitHub,
      GitInspect,
      ChannelActions,
      Scheduler,
      Timer,
      TimerServer,
      Browser,
      Media,
      Workflow,
      SessionSearch,
      Config,
      Orchestrator,
      BlackboardReader,
      GraphMemory,
      CodeSkeleton,
      Learning,
      ExternalKnowledge
    ]
end
