# Final verification script
input = """
Olá!

Tudo bem?**Aqui está a mensagem formatada com HTML:**
Texto tachado aqui: ~~Texto tachado aqui~~           
Código inline: <code>Este é um código inline</code>

Bloco de código:

<pre><code>
def hello():
    print("Hello World!")
</code></pre>

Link: [Clique aqui para visitar o Telegram](https://telegram.org/)                                        
Citação formatada:


> "Essa é uma citação formatada com blockquote."

Negrito + itálico combinado: <b><i>Negrito + itálico juntos no mesmo texto.</i></b>                       
Sublinhado com tachado combinado: <u><s>Sublinhado com tachado combinado</s></u>                          
Finalização:

Formatando no Telegram com sintaxe HTML!

---

Como usar no Telegram: Cole o bloco acima no campo de mensagem e ative parse_mode='HTML' (se possível no seu cliente). 🎨                                      
"""

IO.puts("--- OUTPUT (Pincer Professional Renderer) ---")
try do
  output = Pincer.Channels.Telegram.markdown_to_html(input)
  IO.puts(output)
rescue
  e -> IO.inspect(e)
end
