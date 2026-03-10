defmodule Pincer.Core.ErrorUXTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.ErrorUX

  describe "friendly/2" do
    test "maps HTTP auth errors" do
      assert ErrorUX.friendly({:http_error, 401, "x"}) =~ "401"
      assert ErrorUX.friendly({:http_error, 403, "x"}) =~ "403"
      assert ErrorUX.friendly({:http_error, 404, "x"}) =~ "404"
    end

    test "maps HTTP rate limit and server errors" do
      assert ErrorUX.friendly({:http_error, 429, "x"}) =~ "429"
      assert ErrorUX.friendly({:http_error, 502, "x"}) =~ "instavel"
    end

    test "maps context overflow 400 with actionable guidance" do
      msg =
        ErrorUX.friendly(
          {:http_error, 400,
           "This model's maximum context length is 131072 tokens and your request has 97819 input tokens"}
        )

      assert msg =~ "/reset"
      assert msg =~ "contexto"
    end

    test "maps transport errors" do
      assert ErrorUX.friendly(%Req.TransportError{reason: :timeout}) =~ "Timeout"
      assert ErrorUX.friendly(%Req.TransportError{reason: :econnrefused}) =~ "Conexao recusada"
      assert ErrorUX.friendly(%Req.TransportError{reason: :nxdomain}) =~ "DNS"
    end

    test "maps nested errors" do
      msg = ErrorUX.friendly({:error, {:http_error, 429, "x"}})
      assert msg =~ "429"
    end

    test "maps internal timeout and tool loop" do
      assert ErrorUX.friendly({:timeout, :gen_server_call}) =~ "tempo limite"
      assert ErrorUX.friendly(:tool_loop) =~ "ciclo de ferramentas"
      assert ErrorUX.friendly({:retry_timeout, :x}) =~ "tempo maximo"
    end

    test "maps database schema issue" do
      msg = ErrorUX.friendly(%RuntimeError{message: "undefined table: cron_jobs"})
      assert msg =~ "nao esta migrado"
    end

    test "maps decode/match/function class errors" do
      assert ErrorUX.friendly(%Jason.DecodeError{data: "x", position: 1, token: nil}) =~ "JSON"
      assert ErrorUX.friendly(%FunctionClauseError{}) =~ "formato inesperado"
      assert ErrorUX.friendly(%CaseClauseError{term: :x}) =~ "inesperada"
      assert ErrorUX.friendly(%MatchError{term: :x}) =~ "inconsistencia"
    end

    test "maps stream payload protocol errors" do
      msg =
        ErrorUX.friendly(%Protocol.UndefinedError{
          protocol: Collectable,
          value: :stream,
          description: ""
        })

      assert msg =~ "streaming"
      assert msg =~ "/reset"

      assert ErrorUX.friendly({:invalid_stream_response, :bad}) =~ "formato invalido"
    end

    test "maps undefined function and file missing" do
      assert ErrorUX.friendly(%UndefinedFunctionError{}) =~ "incompatibilidade interna"

      assert ErrorUX.friendly(%File.Error{action: "read", reason: :enoent, path: "missing"}) =~
               "arquivo necessario"
    end

    test "fallback differs by scope" do
      assert ErrorUX.friendly(:unknown, scope: :quick_reply) =~ "Nao consegui responder agora"
      assert ErrorUX.friendly(:unknown, scope: :executor) =~ "/status"
    end
  end
end
