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
    reason |> normalize() |> friendly_normalized(scope)
  end

  defp normalize({:error, reason}), do: normalize(reason)
  defp normalize({:EXIT, reason}), do: normalize(reason)
  defp normalize({:shutdown, reason}), do: normalize(reason)
  defp normalize(reason), do: reason

  defp friendly_normalized({:http_error, 401, _}, _scope),
    do:
      "Falha de autenticacao no provedor de IA (401). Verifique as credenciais e tente novamente."

  defp friendly_normalized({:http_error, status, _msg, _meta}, scope),
    do: friendly_normalized({:http_error, status, nil}, scope)

  defp friendly_normalized({:http_error, 403, _}, _scope),
    do: "Acesso negado no provedor de IA (403). Verifique permissoes/plano e tente novamente."

  defp friendly_normalized({:http_error, 404, _}, _scope),
    do: "Endpoint ou modelo nao encontrado (404). Revise provider/modelo em configuracao."

  defp friendly_normalized({:http_error, 400, msg}, _scope) when is_binary(msg) do
    cond do
      tool_calling_unsupported_message?(msg) ->
        "O modelo atual nao suporta uso de ferramentas. Troque para um modelo com tool calling ou siga sem tools nesta conversa."

      context_overflow_message?(msg) ->
      "A conversa ficou grande demais para o contexto do modelo atual. Use /reset para limpar o historico ou troque para um modelo com janela maior."

      true ->
        "Requisicao invalida para o provedor (400). Revise parametros/modelo e tente novamente."
    end
  end

  defp friendly_normalized({:http_error, 429, _}, _scope),
    do: "Estou em limite de requisicoes (429). Aguarde alguns segundos e tente de novo."

  defp friendly_normalized({:http_error, status, _}, _scope) when status >= 500 do
    "O provedor de IA esta instavel (#{status}). Tente novamente em instantes."
  end

  defp friendly_normalized(%Req.TransportError{reason: :timeout}, scope),
    do: "Timeout de rede ao falar com o provedor. #{retry_hint(scope)}"

  defp friendly_normalized(%Req.TransportError{reason: :econnrefused}, scope),
    do: "Conexao recusada pelo servico remoto. #{retry_hint(scope)}"

  defp friendly_normalized(%Req.TransportError{reason: :nxdomain}, _scope),
    do: "Nao consegui resolver o endereco do provedor (DNS). Verifique URL/rede."

  defp friendly_normalized({:timeout, _}, scope),
    do: "A operacao expirou por tempo limite interno. #{retry_hint(scope)}"

  defp friendly_normalized(:tool_loop, _scope),
    do: "Detectei um ciclo de ferramentas e interrompi a execucao para seguranca."

  defp friendly_normalized({:retry_timeout, _}, _scope),
    do: "Atingi o tempo maximo de tentativas para este provedor. Tente novamente em instantes."

  defp friendly_normalized(%Postgrex.Error{postgres: %{code: :undefined_table}}, _scope),
    do: "O banco nao esta migrado (tabela ausente). Execute as migracoes e tente novamente."

  defp friendly_normalized(%Postgrex.Error{} = error, _scope) do
    msg = Exception.message(error)

    if db_schema_message?(msg) do
      "O banco nao esta migrado (tabela ausente). Execute as migracoes e tente novamente."
    else
      "Falha no banco PostgreSQL. Verifique migracoes e disponibilidade do servico."
    end
  end

  defp friendly_normalized(%RuntimeError{message: msg}, _scope) when is_binary(msg) do
    if db_schema_message?(msg) do
      "O banco nao esta migrado (tabela ausente). Execute as migracoes e tente novamente."
    else
      "Tive um erro tecnico temporario. Tente novamente em instantes. Se persistir, use /status."
    end
  end

  defp friendly_normalized(%UndefinedFunctionError{}, _scope),
    do: "Encontrei uma incompatibilidade interna de versao/codigo. Reinicie e tente novamente."

  defp friendly_normalized(%FunctionClauseError{}, _scope),
    do: "Recebi um formato inesperado de dados. Tente repetir a acao."

  defp friendly_normalized(%CaseClauseError{}, _scope),
    do: "Recebi uma resposta inesperada de integracao. Tente novamente."

  defp friendly_normalized(%MatchError{}, _scope),
    do: "Houve inconsistencia interna ao processar resposta. Tente novamente."

  defp friendly_normalized(%Protocol.UndefinedError{protocol: protocol}, _scope)
       when protocol in [Enumerable, Collectable],
       do:
         "Houve instabilidade no streaming da resposta. Tente novamente; se persistir, use /reset para reduzir contexto."

  defp friendly_normalized({:invalid_stream_response, _}, _scope),
    do: "Recebi um formato invalido de streaming do provedor. Tente novamente em instantes."

  defp friendly_normalized(%Jason.DecodeError{}, _scope),
    do: "Recebi uma resposta invalida de integracao (JSON). Tente novamente."

  defp friendly_normalized(%File.Error{reason: :enoent}, _scope),
    do: "Um arquivo necessario nao foi encontrado. Verifique a configuracao e tente novamente."

  defp friendly_normalized(_unknown, :quick_reply),
    do:
      "Nao consegui responder agora por instabilidade temporaria. Tente novamente em alguns segundos."

  defp friendly_normalized(_unknown, _scope),
    do:
      "Tive um erro tecnico temporario. Tente novamente em instantes. Se persistir, use /status."

  defp retry_hint(:quick_reply), do: "Vou tentar novamente se voce reenviar a mensagem."
  defp retry_hint(_), do: "Tente novamente em alguns segundos."

  defp context_overflow_message?(msg) do
    down = String.downcase(msg)

    String.contains?(down, "maximum context length") or
      String.contains?(down, "input tokens") or
      String.contains?(down, "max_tokens") or
      String.contains?(down, "max_completion_tokens")
  end

  defp tool_calling_unsupported_message?(msg) do
    down = String.downcase(msg)

    String.contains?(down, "tool calling") and
      (String.contains?(down, "not supported") or String.contains?(down, "unsupported"))
  end

  defp db_schema_message?(msg) when is_binary(msg) do
    down = String.downcase(msg)

    (String.contains?(down, "no such table") or
       String.contains?(down, "undefined table") or
       String.contains?(down, "does not exist")) and
      (String.contains?(down, "table") or String.contains?(down, "relation"))
  end
end
