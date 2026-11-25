defmodule Pincer.Adapters.Health do
  @moduledoc "HTTP health endpoint adapter."
  use Boundary,
    type: :strict,
    deps: [Pincer.Core, Pincer.Infra, Jason, Plug],
    exports: [Plug]
end
