defmodule Pincer.Core.ErrorUX do
  @moduledoc """
  User-facing error translation layer.

  Converts low-level exceptions/tuples into concise, actionable messages for
  chat channels. Keeps transport/provider details out of user-facing copy while
  preserving technical logs elsewhere.
  """

  @type scope :: :general | :executor | :quick_reply

  @spec friendly(term(), keyword()) :: String.t()
  def friendly(reason, opts \\ []) do
    scope = Keyword.get(opts, :scope, :general)
    normalized = normalize(reason)
    class = Pincer.Core.ErrorClass.classify(normalized)
    friendly_classified(class, normalized, scope)
  end

  defp normalize({:error, reason}), do: normalize(reason)
  defp normalize({:EXIT, reason}), do: normalize(reason)
  defp normalize({:shutdown, reason}), do: normalize(reason)
  defp normalize(reason), do: reason

  defp friendly_classified(:missing_credentials, {:missing_credentials, env_key}, _scope),
    do: "Faltam credenciais do provedor de IA (#{env_key}). Configure a chave e tente novamente."

  defp friendly_classified(:missing_credentials, _reason, _scope),
    do: "Faltam credenciais do provedor de IA. Configure a chave e tente novamente."

  defp friendly_classified(:auth_cooling_down, _reason, _scope),
    do:
      "Todos os perfis de autenticacao deste provedor estao em cooldown. Aguarde um pouco ou troque de provider."

  defp friendly_classified(:http_401, _reason, _scope),
    do:
      "Falha de autenticacao no provedor de IA (401). Verifique as credenciais e tente novamente."

  defp friendly_classified(:http_403, _reason, _scope),
    do: "Acesso negado no provedor de IA (403). Verifique permissoes/plano e tente novamente."

  defp friendly_classified(:http_404, _reason, _scope),
    do: "Endpoint ou modelo nao encontrado (404). Revise provider/modelo em configuracao."

  defp friendly_classified(:tool_calling_unsupported, _reason, _scope),
    do:
      "O modelo atual nao suporta uso de ferramentas. Troque para um modelo com tool calling ou siga sem tools nesta conversa."

  defp friendly_classified(:context_overflow, _reason, _scope),
    do:
      "A conversa ficou grande demais para o contexto do modelo atual. Use /reset para limpar o historico ou troque para um modelo com janela maior."

  defp friendly_classified(:quota_exhausted, _reason, _scope),
    do:
      "O provedor ficou sem saldo/quota para esta conta. Troque de provider ou credencial e tente novamente."

  defp friendly_classified(:http_429, _reason, _scope),
    do: "Estou em limite de requisicoes (429). Aguarde alguns segundos e tente de novo."

  defp friendly_classified(:http_408, _reason, scope),
    do: "O provedor demorou demais para responder (408). #{retry_hint(scope)}"

  defp friendly_classified(:http_5xx, {:http_error, status, _}, _scope) do
    "O provedor de IA esta instavel (#{status}). Tente novamente em instantes."
  end

  defp friendly_classified(:provider_payload, _reason, _scope),
    do:
      "O provedor devolveu um payload de erro fora do formato esperado. Tente novamente; se persistir, troque de provider/modelo."

  defp friendly_classified(:provider_non_json, _reason, _scope),
    do:
      "O provedor devolveu uma resposta nao-JSON/HTML invalida. Verifique o endpoint ou tente outro provider."

  defp friendly_classified(:provider_empty, _reason, _scope),
    do: "O provedor devolveu resposta vazia. Tente novamente em instantes."

  defp friendly_classified(:http_400, _reason, _scope),
    do: "Requisicao invalida para o provedor (400). Revise parametros/modelo e tente novamente."

  defp friendly_classified(:transport_timeout, _reason, scope),
    do: "Timeout de rede ao falar com o provedor. #{retry_hint(scope)}"

  defp friendly_classified(:transport_connect, _reason, scope),
    do: "Conexao recusada pelo servico remoto. #{retry_hint(scope)}"

  defp friendly_classified(:transport_dns, _reason, _scope),
    do: "Nao consegui resolver o endereco do provedor (DNS). Verifique URL/rede."

  defp friendly_classified(:transport_other, _reason, scope),
    do: "Houve uma falha de transporte ao falar com o provedor. #{retry_hint(scope)}"

  defp friendly_classified(:process_timeout, _reason, scope),
    do: "A operacao expirou por tempo limite interno. #{retry_hint(scope)}"

  defp friendly_classified(:tool_loop, _reason, _scope),
    do: "Detectei um ciclo de ferramentas e interrompi a execucao para seguranca."

  defp friendly_classified(:retry_timeout, _reason, _scope),
    do: "Atingi o tempo maximo de tentativas para este provedor. Tente novamente em instantes."

  defp friendly_classified(:db_schema, _reason, _scope),
    do: "O banco nao esta migrado (tabela ausente). Execute as migracoes e tente novamente."

  defp friendly_classified(:db, _reason, _scope),
    do: "Falha no banco PostgreSQL. Verifique migracoes e disponibilidade do servico."

  defp friendly_classified(:internal, %UndefinedFunctionError{}, _scope),
    do: "Encontrei uma incompatibilidade interna de versao/codigo. Reinicie e tente novamente."

  defp friendly_classified(:internal, %FunctionClauseError{}, _scope),
    do: "Recebi um formato inesperado de dados. Tente repetir a acao."

  defp friendly_classified(:internal, %CaseClauseError{}, _scope),
    do: "Recebi uma resposta inesperada de integracao. Tente novamente."

  defp friendly_classified(:internal, %MatchError{}, _scope),
    do: "Houve inconsistencia interna ao processar resposta. Tente novamente."

  defp friendly_classified(:stream_payload, _reason, _scope),
    do:
      "Houve instabilidade no streaming da resposta. Tente novamente; se persistir, use /reset para reduzir contexto."

  defp friendly_classified(:internal, %Jason.DecodeError{}, _scope),
    do: "Recebi uma resposta invalida de integracao (JSON). Tente novamente."

  defp friendly_classified(:internal, %File.Error{reason: :enoent}, _scope),
    do: "Um arquivo necessario nao foi encontrado. Verifique a configuracao e tente novamente."

  defp friendly_classified(:unknown, _unknown, :quick_reply),
    do:
      "Nao consegui responder agora por instabilidade temporaria. Tente novamente em alguns segundos."

  defp friendly_classified(_class, _unknown, _scope),
    do:
      "Tive um erro tecnico temporario. Tente novamente em instantes. Se persistir, use /status."

  defp retry_hint(:quick_reply), do: "Vou tentar novamente se voce reenviar a mensagem."
  defp retry_hint(_), do: "Tente novamente em alguns segundos."
end
