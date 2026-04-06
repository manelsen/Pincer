# Run with: mix run test/bench/session_bench.exs

defmodule Pincer.Bench.Session do
  @moduledoc "Benchmark suite for session context operations."

  def run do
    # Build a sample context
    context = %{
      session_id: "bench_session",
      history:
        Enum.map(1..50, fn i ->
          %{
            "role" => if(rem(i, 2) == 0, do: "assistant", else: "user"),
            "content" => "Message number #{i} with some content to simulate real usage."
          }
        end),
      metadata: %{channel: :cli, user_id: "bench_user"}
    }

    Benchee.run(
      %{
        "context_size_estimate" => fn ->
          :erlang.term_to_binary(context) |> byte_size()
        end,
        "history_slice_last_20" => fn ->
          Enum.take(context.history, -20)
        end,
        "history_token_count_estimate" => fn ->
          context.history
          |> Enum.map(fn m -> String.length(m["content"]) end)
          |> Enum.sum()
          # rough chars-to-tokens estimate
          |> div(4)
        end
      },
      time: 5,
      warmup: 1,
      formatters: [Benchee.Formatters.Console]
    )
  end
end

Pincer.Bench.Session.run()
