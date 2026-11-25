defmodule Pincer.Channels do
  @moduledoc "Channel Adapters."
  use Boundary,
    deps: [Pincer.Infra, Pincer.Plugin, PincerPorts],
    exports: []
end
