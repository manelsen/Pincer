defmodule Pincer.Adapters.Connectors do
  @moduledoc "External service connectors."
  use Boundary,
    deps: [Pincer.Core, Pincer.Ports, Pincer.Infra],
    exports: [MCP.Manager]
end
