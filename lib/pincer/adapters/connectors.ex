defmodule Pincer.Adapters.Connectors do
  @moduledoc "External service connectors."
  use Boundary,
    type: :strict,
    deps: [Pincer.Core, Pincer.Utils, Jason, Logger, Req],
    exports: [MCP.Manager]
end
