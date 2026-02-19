defmodule Pincer.Core.Bootstrap do
  @moduledoc """
  Gerencia o ritual de nascimento do Pincer seguindo os princípios de SoulCraft.
  A alma é forjada em diálogo, evitando clichês de assistente virtual.
  """

  alias Pincer.LLM.Client

  @questions [
    %{id: :name, text: "Como você quer batizar esta instância técnica?"},
    %{
      id: :stance,
      text: "Em uma escala de 'purista técnico da BEAM' a 'parceiro criativo', onde eu me sento?"
    },
    %{
      id: :truth,
      text:
        "Qual é o princípio inegociável que deve guiar minhas respostas? (Ex: Precisão absoluta, sinal puro, velocidade)"
    },
    %{
      id: :conflict,
      text:
        "Se eu detectar uma falha no seu raciocínio ou código, devo ser seco e direto ou suavizar a crítica?"
    },
    %{
      id: :user_context,
      text: "Qual é o contexto do seu dia a dia que eu devo carregar como prioridade?"
    }
  ]

  def questions, do: @questions
  def first_question, do: List.first(@questions)

  def next_question(current_id) do
    index = Enum.find_index(@questions, fn q -> q.id == current_id end)
    Enum.at(@questions, index + 1)
  end

  def last_question?(current_id) do
    List.last(@questions).id == current_id
  end

  def consolidate(responses) do
    prompt = """
    Você é um Arquiteto de Sistemas e Comportamento. Sua missão é forjar a identidade de um Agente Elixir chamado Pincer.
    Fuja OBRIGATORIAMENTE de clichês de "assistente de IA prestativo". O Pincer deve soar como uma extensão técnica do usuário.

    RESPOSTAS DO DIRETOR (MANEL):
    - Nome: #{responses[:name]}
    - Stance: #{responses[:stance]}
    - Verdade Core: #{responses[:truth]}
    - Gestão de Conflito: #{responses[:conflict]}
    - Contexto: #{responses[:user_context]}

    Gere três arquivos Markdown elegantes:
    1. `IDENTITY.md`: Nome, Criatura (Agente Elixir/BEAM), Vibe e Emoji.
    2. `SOUL.md`: 
       - Core Truths (3-5 princípios baseados na 'Verdade Core' e 'Stance').
       - Boundaries (o que ele NÃO fará, baseado na 'Gestão de Conflito').
       - Vibe (estilo de voz e tom).
    3. `USER.md`: Quem é o Manel e como o agente deve servi-lo.

    REGRAS DE OURO:
    - Proibido usar "Sou uma inteligência artificial...", "Estou aqui para ajudar", "Como posso ser útil?".
    - Tom deve ser de competência, sinal puro e parceria técnica.
    - Se o usuário disse para ser seco e direto, a alma deve refletir isso em cada linha.

    Retorne APENAS um JSON puro: {"identity": "content...", "soul": "content...", "user": "content..."}
    """

    case Client.chat_completion([%{"role" => "system", "content" => prompt}]) do
      {:ok, %{"content" => content}} ->
        clean_content =
          content
          |> String.replace(~r/^```json\n/, "")
          |> String.replace(~r/\n```$/, "")
          |> String.trim()

        case Jason.decode(clean_content) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, _} -> {:error, :invalid_format}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
