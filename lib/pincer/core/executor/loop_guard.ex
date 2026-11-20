defmodule Pincer.Core.Executor.LoopGuard do
  @moduledoc """
  Pure recursion-depth and tool-call loop detection for the agent executor.
  """

  @identical_window 10
  @identical_threshold 3
  @frequency_window 15
  @frequency_threshold 10

  @doc """
  Validates recursion `depth` against `max_depth` and inspects `history` for
  repetitive tool-call loops.
  """
  @spec check([map()], non_neg_integer(), pos_integer()) ::
          :ok | {:error, {:depth_exceeded, non_neg_integer()}} | {:error, :tool_loop}
  def check(history, depth, max_depth) when is_list(history) do
    cond do
      depth > max_depth -> {:error, {:depth_exceeded, depth}}
      loop_detected?(history) -> {:error, :tool_loop}
      true -> :ok
    end
  end

  @doc """
  Returns `true` when `history` exhibits either 3+ consecutive identical
  tool-call sets or the same `{name, args}` call 10+ times in the last 15 turns.
  """
  @spec loop_detected?([map()]) :: boolean()
  def loop_detected?(history) when is_list(history) do
    identical_sequence_loop?(history) or high_frequency_loop?(history)
  end

  defp identical_sequence_loop?(history) do
    assistant_msgs =
      history
      |> Enum.take(-@identical_window)
      |> Enum.filter(fn
        %{"role" => "assistant", "tool_calls" => calls} -> is_list(calls) and calls != []
        _ -> false
      end)

    if length(assistant_msgs) >= @identical_threshold do
      fingerprints =
        assistant_msgs
        |> Enum.take(-@identical_threshold)
        |> Enum.map(fn %{"tool_calls" => calls} ->
          calls
          |> Enum.map(&tool_pair/1)
          |> Enum.sort()
        end)

      case Enum.uniq(fingerprints) do
        [_single] -> true
        _ -> false
      end
    else
      false
    end
  end

  defp high_frequency_loop?(history) do
    recent_pairs =
      history
      |> Enum.take(-@frequency_window)
      |> Enum.flat_map(fn
        %{"tool_calls" => calls} when is_list(calls) -> Enum.map(calls, &tool_pair/1)
        _ -> []
      end)
      |> Enum.reject(fn {name, _args} -> is_nil(name) end)

    recent_pairs
    |> Enum.frequencies()
    |> Enum.any?(fn {_pair, count} -> count >= @frequency_threshold end)
  end

  defp tool_pair(call) do
    {get_in(call, ["function", "name"]), get_in(call, ["function", "arguments"])}
  end
end
