defmodule Pincer.Plugin do
  @moduledoc "Plugin discovery and manifest parsing for Pincer's extension system."
  use Boundary,
    deps: [],
    exports: [Manifest]
end
