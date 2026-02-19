defmodule Pincer.Channels.Factory do
  @moduledoc """
  Factory de Canais.
  Responsável por ler a configuração e instanciar os canais habilitados dinamicamente.
  """
  require Logger

  @doc """
  Lê a configuração (YAML) e retorna a lista de children specs para o Supervisor.
  """
  def create_channel_specs(config \\ nil) do
    config = config || Pincer.Config.get(:channels, %{})
    
    # Verifica se há um override de runtime (ex: via mix task)
    whitelist = Application.get_env(:pincer, :enabled_channels)

    config
    |> Enum.filter(fn {name, cfg} -> 
      if whitelist do
        # Se houver whitelist, só sobe se o nome estiver nela
        name in whitelist
      else
        # Comportamento padrão: respeita o config.yaml
        cfg["enabled"] == true
      end
    end)
    |> Enum.map(fn {name, cfg} ->
      module_name = cfg["adapter"]
      module = Module.concat([module_name])

      Logger.info("Habilitando Canal: #{name} (#{module_name})")
      
      # Retorna o Child Spec (para iniciar o processo)
      {module, cfg}
    end)
  end
end
