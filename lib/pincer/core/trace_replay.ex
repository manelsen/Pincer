defmodule Pincer.Core.TraceReplay do
  @moduledoc """
  Side-effect-free trace replay engine.

  Replays recorded trace steps deterministically from persisted data and never
  executes external tools/providers.
  """

  @type replay_result :: %{
          mode: :no_side_effects,
          steps_replayed: non_neg_integer(),
          executed_tools: list(),
          stopped_at: :end | :tool_boundary
        }

  @doc """
  Replays a trace envelope using recorded step data only.

  ## Options
  - `:stop_at` - `:tool_boundary` to stop once the first tool step is reached.
  """
  @spec replay(map(), keyword()) :: replay_result()
  def replay(trace, opts \\ []) when is_map(trace) and is_list(opts) do
    stop_at = Keyword.get(opts, :stop_at, :end)
    steps = Map.get(trace, :steps, [])

    {replayed, stopped_at} =
      Enum.reduce_while(steps, {0, :end}, fn step, {count, _} ->
        if stop_at == :tool_boundary and Map.get(step, :kind) == :tool do
          {:halt, {count + 1, :tool_boundary}}
        else
          {:cont, {count + 1, :end}}
        end
      end)

    %{
      mode: :no_side_effects,
      steps_replayed: replayed,
      executed_tools: [],
      stopped_at: stopped_at
    }
  end
end
