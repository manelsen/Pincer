# Configurando o Opencode Zen

O Pincer suporta múltiplos provedores LLM através do `Pincer.LLM.Client` (`config/config.exs` define `"openrouter"` como fallback em tempo de compilação e o `config.yaml` padrão usa `"groq"` em runtime). Siga os passos abaixo para ativar o **Opencode Zen**.

## Configuração

### 1. Variável de Ambiente

Adicione sua chave API do Opencode Zen ao arquivo `.env`:

```bash
OPENCODE_ZEN_API_KEY=sua_chave_aqui
```

### 2. Configuração YAML

Ajuste `llm.provider` e o bloco do provedor no `config.yaml`:

```yaml
llm:
  provider: "opencode_zen"  # ou "groq" / "openrouter"
  opencode_zen:
    default_model: "kimi-k2.5-free"
  openrouter:
    base_url: "https://openrouter.ai/api/v1/chat/completions"
    default_model: "google/gemini-2.0-flash-exp:free"
```

### 3. Alternando Provedores

Para usar o OpenRouter em vez do Opencode Zen, altere o `provider` no `config.yaml`:

```yaml
llm:
  provider: "openrouter"
```

## Modelos Suportados

### Opencode Zen
- `moonshot-v1-8k` (Kimi 2.5 equivalente)

### OpenRouter
- `stepfun/step-3.5-flash:free`
- `openrouter/aurora-alpha`
- E outros disponíveis no catálogo do OpenRouter

## Verificação

Ao iniciar o Pincer, você verá:

```
LLM Provider: opencode_zen
Token ENV Opencode Zen: OK
```

Se a chave não estiver configurada, o sistema usará modo MOCK.
