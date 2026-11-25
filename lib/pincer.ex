defmodule Pincer do
  @moduledoc "Autonomous AI Agent Framework."
  use Boundary, deps: [PincerPorts]
end

defmodule Pincer.Mix do
  @moduledoc """
  Top-level boundary scope for Mix tasks and compilation checks.
  """
  use Boundary, top_level?: true, check: [in: false, out: false]
end
