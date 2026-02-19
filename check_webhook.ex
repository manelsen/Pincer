defmodule CheckWebhook do
  def run(token) do
    url = "https://api.telegram.org/bot#{token}/getWebhookInfo"
    
    case Req.get(url) do
      {:ok, %{body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"ok" => true, "result" => result}} ->
            if result["url"] == "" do
              IO.puts("✅ Webhook desativado (URL vazia). Polling deve funcionar.")
            else
              IO.puts("⚠️  WEBHOOK ATIVO DETECTADO!")
              IO.puts("URL: #{result["url"]}")
              IO.puts("Isso impede que o polling receba atualizações.")
              IO.puts("")
              IO.puts("Desative com:")
              IO.puts("  https://api.telegram.org/bot#{token}/deleteWebhook")
            end
          
          {:ok, %{"ok" => false, "description" => desc}} ->
            IO.puts("❌ Erro ao verificar webhook:")
            IO.puts(desc)
          
          {:error, reason} ->
            IO.puts("❌ Erro ao decodificar JSON: #{inspect(reason)}")
        end
      
      {:error, reason} ->
        IO.puts("❌ Erro na requisição HTTP: #{inspect(reason)}")
    end
  end
end

token = System.get_env("TELEGRAM_BOT_TOKEN")
CheckWebhook.run(token)
