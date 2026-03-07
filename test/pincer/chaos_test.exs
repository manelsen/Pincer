defmodule Pincer.ChaosTest do
  use ExUnit.Case, async: false
  import Mox
  require Logger

  alias Pincer.Core.Orchestration.Blackboard

  setup :set_mox_from_context

  setup do
    # Stub global para aguentar chamadas massivas sem ownership issues
    Pincer.LLM.ClientMock
    |> stub(:chat_completion, fn _msgs, _model, _config, _tools ->
      {:ok, %{"content" => "Tester: RED\nCoder: GREEN"}}
    end)

    case Process.whereis(Blackboard) do
      nil -> Blackboard.start_link([])
      _ -> :ok
    end

    Blackboard.reset()
    :ok
  end

  @tag :chaos
  test "ULTRA STRESS TEST: 100,000 operations" do
    n = 100_000
    Logger.info("☢️ INICIANDO PROTOCOLO CHAOS v3: #{n} operações...")

    start_time = System.monotonic_time()

    # 1. Bombardeio no Blackboard usando stream para manter pressão constante
    # Concorrência de 100 processos simultâneos disparando casts
    1..n
    |> Task.async_stream(
      fn i ->
        Blackboard.post("chaos_bot", "Pressure test message #{i}", "p-chaos")
      end,
      max_concurrency: 100,
      timeout: :infinity
    )
    |> Stream.run()

    end_time = System.monotonic_time()
    duration = System.convert_time_unit(end_time - start_time, :native, :millisecond)

    Logger.info(
      "📊 Bombardeio concluído em #{duration}ms. (#{Float.round(n / (duration / 1000), 2)} ops/sec)"
    )

    # 2. Verificação de integridade
    {msgs, last_id} = Blackboard.fetch_new(0)
    Logger.info("✅ Blackboard integrada. Mensagens: #{length(msgs)}. Last ID: #{last_id}")

    assert length(msgs) == n
    assert last_id == n

    # 3. Teste de latência de leitura com base de dados cheia
    {read_duration, _} = :timer.tc(fn -> Blackboard.fetch_new(n - 100) end)
    Logger.info("⏱️ Latência de leitura (últimas 100 de 100k): #{read_duration} microsegundos.")

    # Deve ler 100 mensagens em menos de 50ms (geralmente < 1ms em ETS)
    assert read_duration < 50_000

    Logger.info("🏆 BEAM invicto. 100k operações processadas com integridade total.")
  end
end
