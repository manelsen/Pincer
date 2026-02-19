defmodule Pincer.Core.Heartbeat do
  @moduledoc """
  Pulso periódico do Pincer.
  Acorda o agente proativamente para verificar o status do mundo (ex: GitHub).
  """
  use GenServer
  require Logger

  # Intervalo do Heartbeat (ex: 1 hora)
  @interval 60 * 60 * 1000 

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(state) do
    Logger.info("Coração do Pincer começou a bater.")
    schedule_pulse()
    {:ok, state}
  end

  @impl true
  def handle_info(:pulse, state) do
    Logger.info("[HEARTBEAT] Pulso detectado. Verificando proatividade...")
    
    # Exemplo de tarefa proativa: Notificar o Manel que o Pincer está atento.
    # No futuro, aqui chamaremos um Worker específico para buscar novidades no GitHub.
    # Dispatcher.dispatch("telegram_924255495", "⚙️ Pulso de rotina: sistemas operacionais. Alguma tarefa para agora, Manel?")
    
    schedule_pulse()
    {:noreply, state}
  end

  defp schedule_pulse do
    Process.send_after(self(), :pulse, @interval)
  end
end
