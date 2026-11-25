defmodule Pincer.Core.Session do
  @moduledoc "Session lifecycle and conversation state."

  use Boundary,
    deps: [
      Pincer.Core,
      Pincer.Core.Executor,
      Pincer.Core.Graph,
      Pincer.Core.Introspection,
      Pincer.Core.LLM,
      Pincer.Core.Memory,
      Pincer.Core.Orchestration,
      Pincer.Core.Project
    ],
    exports: [Adapter, AlignmentIntegrity, HordeSupervisor, Server, SubAgentProgress, Supervisor]
end
