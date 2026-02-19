defmodule Pincer.PubSub do
  @moduledoc """
  Barramento de Eventos do Pincer.
  Permite que o Core seja agnóstico aos canais de saída.
  
  Padrão:
  - Canais (Adapters) se inscrevem em tópicos de sessão.
  - O Core (Domain) publica mensagens nesses tópicos.
  """

  # Usa o Registry nativo do Elixir como PubSub local
  @registry_name Pincer.PubSub.Registry

  def child_spec(_) do
    Registry.child_spec(
      keys: :duplicate,
      name: @registry_name,
      partitions: System.schedulers_online()
    )
  end

  @doc """
  Inscreve o processo atual para receber eventos de uma sessão específica.
  Ex: Pincer.PubSub.subscribe("session:cli_user")
  """
  def subscribe(topic) do
    Registry.register(@registry_name, topic, [])
  end

  @doc """
  Transmite uma mensagem para todos os inscritos no tópico.
  A mensagem é enviada diretamente para a caixa de correio dos processos (handle_info).
  """
  def broadcast(topic, message) do
    Registry.dispatch(@registry_name, topic, fn entries ->
      for {pid, _} <- entries, do: send(pid, message)
    end)
  end
end
