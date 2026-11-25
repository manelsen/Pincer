defmodule Pincer.Telemetry do
  @moduledoc "Telemetry and metrics boundary."
  use Boundary, deps: [], exports: [PromEx]
end
