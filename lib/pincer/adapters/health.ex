defmodule Pincer.Adapters.Health do
  @moduledoc "HTTP health endpoint adapter."
  use Boundary,
    deps: [Pincer.Core, Pincer.Ports, Pincer.Infra],
    exports: [Plug]
end
