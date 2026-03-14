defmodule Pincer.Core.ToolOnlyOutcomeFormatterTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.ToolOnlyOutcomeFormatter

  test "formats tool-only outcome as partial response instead of success" do
    text =
      ToolOnlyOutcomeFormatter.format([
        %{"name" => "web", "content" => "Results for 'www.cade.com.br site': HOME — CADE"},
        %{
          "name" => "browser",
          "content" => ~s(Error: "browser pool unavailable: process not started")
        }
      ])

    refute text =~ "✅ Concluído"
    assert text =~ "Nao consegui fechar uma resposta final"
    assert text =~ "web, browser"
    assert text =~ "HOME — CADE"
    assert text =~ "browser pool unavailable"
  end

  test "flags tool failures explicitly when summary contains errors" do
    text =
      ToolOnlyOutcomeFormatter.format([
        %{
          "name" => "web",
          "content" =>
            ~s(Error: "Fetch failed: %Req.TransportError{reason: {:tls_alert, :handshake_failure}}")
        }
      ])

    assert text =~ "Algumas ferramentas falharam"
    assert text =~ "Fetch failed"
  end

  test "extracts useful summary from GitHub issue JSON when final answer is missing" do
    text =
      ToolOnlyOutcomeFormatter.format([
        %{
          "name" => "get_issue",
          "content" =>
            ~s({"number":168,"title":"OpenClaw ecosystem daily report","state":"open","html_url":"https://github.com/duanyytop/agents-radar/issues/168"})
        }
      ])

    assert text =~ "Consegui obter dados pelas ferramentas"
    assert text =~ "Issue #168: OpenClaw ecosystem daily report"
    assert text =~ "State: open"
    assert text =~ "github.com/duanyytop/agents-radar/issues/168"
  end

  test "extracts concise git summary from git_inspect output" do
    text =
      ToolOnlyOutcomeFormatter.format([
        %{
          "name" => "git_inspect",
          "content" => "## feature/demo\n M notes.txt\n?? scratch.txt\n"
        }
      ])

    assert text =~ "Consegui obter dados pelas ferramentas"
    assert text =~ "## feature/demo"
    assert text =~ "M notes.txt"
    refute text =~ "Ferramentas utilizadas: git_inspect\n\nResumo parcial:"
  end
end
