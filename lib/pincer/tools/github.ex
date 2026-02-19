defmodule Pincer.Tools.GitHub do
  @moduledoc """
  Ferramenta nativa para interagir com o GitHub usando a API REST diretamente.
  Garante que os dados sejam do usuário dono do token.
  """
  @behaviour Pincer.Tool
  require Logger

  def spec do
    %{
      name: "get_my_github_repos",
      description: "Lista todos os repositórios reais do usuário autenticado no GitHub. Usa o token do ambiente para garantir a identidade.",
      parameters: %{
        type: "object",
        properties: %{
          visibility: %{
            type: "string",
            enum: ["all", "public", "private"],
            description: "Filtrar por visibilidade (padrão: all)."
          }
        }
      }
    }
  end

  def execute(args) do
    token = System.get_env("GITHUB_PERSONAL_ACCESS_TOKEN")
    visibility = Map.get(args, "visibility", "all")

    if is_nil(token) or token == "" do
      {:error, "GITHUB_PERSONAL_ACCESS_TOKEN não configurado no .env"}
    else
      url = "https://api.github.com/user/repos"
      params = [visibility: visibility, sort: "updated", per_page: 50]

      case Req.get(url, 
             auth: {:bearer, token}, 
             params: params,
             headers: [{"Accept", "application/vnd.github.v3+json"}]
           ) do
        {:ok, %{status: 200, body: repos}} when is_list(repos) ->
          summary = repos 
          |> Enum.map(fn r -> 
            "- **#{r["name"]}** (#{r["full_name"]})\n  Atualizado em: #{r["updated_at"]}\n  URL: #{r["html_url"]}" 
          end)
          |> Enum.join("\n")
          
          {:ok, "Encontrei #{length(repos)} repositórios:\n\n" <> summary}

        {:ok, %{status: status, body: body}} ->
          {:error, "GitHub API retornou status #{status}: #{inspect(body)}"}

        {:error, reason} ->
          {:error, "Falha na requisição GitHub: #{inspect(reason)}"}
      end
    end
  end
end
