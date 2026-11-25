defmodule Pincer.Adapters do
  @moduledoc "Registry and umbrella for all Adapters."
  use Boundary,
    deps: [Pincer.Core, Pincer.Ports, Pincer.Infra, Pincer.Utils],
    exports: [Storage.SQLite, Storage.Checkpoint, Storage.MemoryHelpers]
end
