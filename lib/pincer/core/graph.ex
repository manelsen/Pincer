defmodule Pincer.Core.Graph do
  @moduledoc "Workspace graph synchronization and observation."

  use Boundary,
    deps: [],
    exports: [Sync, Watcher]
end
