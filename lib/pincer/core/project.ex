defmodule Pincer.Core.Project do
  @moduledoc "Project commands and durable execution state."

  use Boundary,
    deps: [Pincer.Core, Pincer.Core.Executor, Pincer.Core.Orchestration],
    exports: [
      Adapter,
      HordeSupervisor,
      Plan,
      ProjectRouter,
      Recovery,
      Renderer,
      Store,
      Supervisor,
      Wizard
    ]
end
