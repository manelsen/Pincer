#!/usr/bin/env mix script.main

defmodule CheckWebhook do
  def main([]) do
    token = System.get_env("TELEGRAM_BOT_TOKEN")
    
    unless token do
      IO.puts("Erro: Token não encontrado em TELEGRAM_BOT_TOKEN")
      System.halt(1)
    end
    
    url = "https://api.telegram.org/bot#{token}/getWebhookInfo"
    
    IO.puts("Verificando status do webhook...")
    
    case Req.get(url) do
      {:ok, %{body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"ok" => true, "result" => result}} ->
            if result["url"] == "" do
              IO.puts("✅ Webhook desativado (URL vazia). Polling deve funcionar.")
            else
              IO.puts("")
              IO.puts("⚠️  WEBHOOK ATIVO DETECTADO!")
              IO.puts("URL: #{result["url"]}")
              IO.puts("")
              IO.puts("Isso impede que o polling receba atualizações de callback_query.")
              IO.puts("")
              IO.puts("Para desativar manualment, acesse:")
              IO.puts("  https://api.telegram.org/bot#{token}/deleteWebhook")
              IO.puts("")
              IO.puts("Ou execute no Elixir:")
              IO.puts("  ExGram.delete_webhook(token: \"#{token}\")")
            end
          
          {:ok, %{"ok" => false, "description" => desc}} ->
            IO.puts("❌ Erro ao verificar webhook:")
            IO.puts(desc)
          
          {:error, reason} ->
            IO.puts("❌ Erro ao decodificar JSON:")
            IO.puts(inspect(reason))
        end
      
      {:error, reason} ->
        IO.puts("❌ Erro na requisição HTTP:")
        IO.puts(inspect(reason))
    end
  end
end
