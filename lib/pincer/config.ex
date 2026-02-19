defmodule Pincer.Config do
  @moduledoc """
  Configuration loader for Pincer using YAML and Dotenv.
  """

  @config_file "config.yaml"

  def load do
    # 1. Tenta carregar o .env usando File.read para maior controle
    IO.puts("Carregando variáveis de ambiente do .env...")
    case File.read(".env") do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.each(fn line ->
          case String.split(line, "=", parts: 2) do
            [key, value] -> 
              trimmed_key = String.trim(key)
              trimmed_value = String.trim(value) |> String.trim("\"") |> String.trim("'")
              System.put_env(trimmed_key, trimmed_value)
            _ -> :ok
          end
        end)
      {:error, _} -> 
        IO.puts("Aviso: Arquivo .env não encontrado.")
    end

    # 2. Carrega o YAML (Apenas para configurações não sensíveis)
    case YamlElixir.read_from_file(@config_file) do
      {:ok, config} ->
        # Salva config estrutural
        Enum.each(config, fn {key, value} ->
          Application.put_env(:pincer, String.to_atom(key), value)
        end)

        # 3. Tokens (Apenas via Variáveis de Ambiente)
        env_telegram = System.get_env("TELEGRAM_BOT_TOKEN")
        env_openrouter = System.get_env("OPENROUTER_API_KEY")
        env_opencode_zen = System.get_env("OPENCODE_ZEN_API_KEY")
        
        IO.puts("Token ENV Telegram: #{if env_telegram && env_telegram != "", do: "OK", else: "NÃO ENCONTRADO"}")
        IO.puts("Token ENV Opencode Zen: #{if env_opencode_zen && env_opencode_zen != "", do: "OK", else: "NÃO ENCONTRADO"}")
        
        tokens = %{
          "telegram" => env_telegram,
          "openrouter" => env_openrouter,
          "opencode_zen" => env_opencode_zen
        }
        
        # Filtra nils/vazios
        final_tokens = 
          tokens 
          |> Enum.filter(fn {_, v} -> v != nil && v != "" end)
          |> Map.new()
        
        Application.put_env(:pincer, :tokens, final_tokens)

        # 4. Configuração LLM (Provedores)
        if llm_config = config["llm"] do
          Application.put_env(:pincer, :llm, llm_config)
          
          provider = llm_config["provider"] || "openrouter"
          IO.puts("LLM Provider: #{provider}")
        end

        # 5. Configuração do Repo
        if db_config = config["database"] do
          current_repo_config = Application.get_env(:pincer, Pincer.Repo, [])
          
          ecto_config = 
            db_config 
            |> Enum.map(fn {k, v} -> {String.to_atom(k), v} end)
            |> Keyword.merge(current_repo_config)

          ecto_config = 
            case db_config["adapter"] do
              "Ecto.Adapters.SQLite3" -> Keyword.put(ecto_config, :adapter, Ecto.Adapters.SQLite3)
              "Ecto.Adapters.PostgreSQL" -> Keyword.put(ecto_config, :adapter, Ecto.Adapters.PostgreSQL)
              _ -> ecto_config
            end

          Application.put_env(:pincer, :repo, ecto_config)
        end

        :ok

      {:error, reason} ->
        IO.puts("Erro fatal: Falha ao carregar config.yaml: #{inspect(reason)}")
        :error
    end
  end

  def get(key, default \\ nil) do
    Application.get_env(:pincer, key, default)
  end

  def fetch!(key) do
    Application.fetch_env!(:pincer, key)
  end

  def set_model(model_id, provider \\ nil) do
    case YamlElixir.read_from_file(@config_file) do
      {:ok, config} ->
        # Atualiza o modelo no provider correto ou no provider atual
        current_provider = provider || Map.get(config["llm"], "provider", "openrouter")
        
        new_llm = 
          config["llm"]
          |> Map.put("provider", current_provider)
          |> put_in([current_provider, "default_model"], model_id)

        new_config = Map.put(config, "llm", new_llm)

        # Escreve de volta no YAML
        case write_yaml(@config_file, new_config) do
          :ok ->
            # Recarrega a config na Application Elixir
            load()
            {:ok, model_id, current_provider}
          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write_yaml(path, config) do
    # Constrói o conteúdo preservando a seção mcp se existir
    mcp_section = if config["mcp"] do
      """
      mcp:
        servers:
          #{Enum.map(config["mcp"]["servers"], fn {name, cfg} ->
            "#{name}:\n      command: \"#{cfg["command"]}\"\n      args: #{inspect(cfg["args"])}"
          end) |> Enum.join("\n    ")}
      """
    else
      ""
    end

    content = """
    database:
      adapter: "#{config["database"]["adapter"]}"
      database: "#{config["database"]["database"]}"

    llm:
      provider: "#{config["llm"]["provider"]}"
      opencode_zen:
        base_url: "#{config["llm"]["opencode_zen"]["base_url"]}"
        default_model: "#{config["llm"]["opencode_zen"]["default_model"]}"
      openrouter:
        base_url: "#{config["llm"]["openrouter"]["base_url"]}"
        default_model: "#{config["llm"]["openrouter"]["default_model"]}"

    #{mcp_section}
    """
    File.write(path, content)
  end
end
