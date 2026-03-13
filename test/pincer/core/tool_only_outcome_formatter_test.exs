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
end
