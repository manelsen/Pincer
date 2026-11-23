defmodule Pincer.Infra do
  @moduledoc "Infrastructure layer."
  use Boundary,
    exports: [
      PubSub,
      Config,
      SQLite
    ]
end
