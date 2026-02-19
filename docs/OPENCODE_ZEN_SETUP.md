# Configurando o Opencode Zen

O Pincer agora suporta múltiplos provedores LLM através do Unified Client. O provedor padrão é o **Opencode Zen**.

## Configuração

### 1. Variável de Ambiente

Adicione sua chave API do Opencode Zen ao arquivo `.env`:

```bash
OPENCODE_ZEN_API_KEY=sua_chave_aqui
```

### 2. Configuração YAML

O arquivo `config.yaml` já está configurado:

```yaml
llm:
  provider: "opencode_zen"  # ou "openrouter"
  opencode_zen:
    api_key: ""  # A chave é carregada do .env
    base_url: "https://api.opencode.zen/v1/chat/completions"
    default_model: "moonshot-v1-8k"
  openrouter:
    api_key: ""  # A chave é carregada do .env
    base_url: "https://openrouter.ai/api/v1/chat/completions"
    default_model: "stepfun/step-3.5-flash:free"
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
