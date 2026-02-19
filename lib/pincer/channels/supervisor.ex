defmodule Pincer.Channels.Supervisor do
  @moduledoc """
  Supervisor de Canais.
  Inicia todos os adaptadores de comunicação configurados em config.yaml.
  """
  use Supervisor
  require Logger
  alias Pincer.Channels.Factory

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    Logger.info("Supervisor de Canais iniciando...")
    
    # Usa a Factory para gerar a lista de processos
    children = Factory.create_channel_specs()

    Supervisor.init(children, strategy: :one_for_one)
  end
end
