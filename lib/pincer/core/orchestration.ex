defmodule Pincer.Core.Orchestration do
  @moduledoc "Sub-agent execution, coordination, and memory consolidation."

  use Boundary,
    deps: [Pincer.Core, Pincer.Core.Executor, Pincer.Core.LLM, Pincer.Core.Memory],
    exports: [Archivist, Blackboard, SubAgent, SubAgentRegistry]
end
