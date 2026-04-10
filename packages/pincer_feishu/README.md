# pincer_feishu

Feishu (Lark) channel adapter for the Pincer AI agent framework.

Part of the [Pincer](https://github.com/manelsen/Pincer) AI agent framework.

## Installation

```elixir
def deps do
  [
    {:pincer_feishu, "~> 0.1"}
  ]
end
```

## Usage

Add to your `config.yaml`:

```yaml
channels:
  feishu:
    enabled: true
    app_id_env: FEISHU_APP_ID
    app_secret_env: FEISHU_APP_SECRET
```

## License

MIT
