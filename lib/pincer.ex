defmodule Pincer do
  @moduledoc "Autonomous AI Agent Framework."
  use Boundary

  @doc """
  Minimal compatibility function kept for the default generated ExUnit smoke test.
  """
  @spec hello() :: :world
  def hello, do: :world
end

defmodule Pincer.Mix do
  @moduledoc false
  use Boundary, top_level?: true, check: [in: false, out: false]
end
