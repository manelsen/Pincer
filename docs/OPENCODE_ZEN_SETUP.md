# Configurando o OpenCode Zen e Alternativas Gratuitas

O Pincer suporta múltiplos provedores LLM através do `Pincer.LLM.Client` (`config/config.exs` define `"openrouter"` como fallback em tempo de compilação e o `config.yaml` padrão usa `"groq"` em runtime). Veja abaixo como ativar o **OpenCode Zen** e as opções gratuitas atuais.

## Configuração do OpenCode Zen

### 1. Variável de Ambiente

Adicione sua chave do OpenCode Zen (gerenciada atualmente pelo **OpenCode Console**) no arquivo `.env`:

```bash
OPENCODE_ZEN_API_KEY=sua_chave_aqui
```

### 2. Configuração YAML

Ajuste `llm.provider` e o bloco do provedor no `config.yaml`:

```yaml
llm:
  provider: "opencode_zen"  # ou "groq" / "openrouter" / "google" / "ollama"
  opencode_zen:
    base_url: "https://opencode.ai/zen/v1/chat/completions"
    default_model: "kimi-k2.5-free"
  openrouter:
    base_url: "https://openrouter.ai/api/v1/chat/completions"
    default_model: "openrouter/free"
```

### 3. Alternando Provedores

Para alternar para o OpenRouter ou outro provedor BYOK no `config.yaml`:

```yaml
llm:
  provider: "openrouter"
```

## Modelos Recomendados (Tier Gratuito / Baixo Custo)

### OpenCode Zen (`opencode.ai/console/models`)
- `kimi-k2.5-free` — modelo gratuito rotativo padrão do gateway OpenCode Zen.
- **Limites do gateway:** o tier gratuito do Zen possui cotas dinâmicas por janela horária; para uso intenso ou pipelines de produção sem throttling, recomenda-se BYOK (Bring Your Own Key) via OpenRouter, Google AI Studio, Groq ou Ollama local.

### OpenRouter (`openrouter.ai`)
- `openrouter/free` — roteador automático padrão que escolhe modelos `:free` disponíveis.
- `google/gemma-4-31b-it:free` — 262K contexto, ótimo custo-benefício em texto e visão.
- `nvidia/nemotron-3.5-lightning:free` — janela longa otimizada para raciocínio multi-etapa.
- `cohere/north-mini-code:free` — focado em fluxo agêntico de código.

### Alternativas BYOK Gratuitas e Local
- **Google AI Studio (`google`):** `gemini-3.8-flash` (baixa latência, `supports_files: true`).
- **Groq Cloud (`groq`):** `openai/gpt-oss-120b` ou `openai/gpt-oss-20b`.
- **Ollama local (`ollama`):** `qwen3.5:9b`, `gemma4:12b` ou `qwen3.8:27b` sem necessidade de API key.

## Verificação

Ao iniciar o Pincer, você verá nos logs:

```text
LLM Provider: opencode_zen
Token ENV Opencode Zen: OK
```

Sem chave configurada, o adaptador entra em modo `MOCK` para desenvolvimento offline.
