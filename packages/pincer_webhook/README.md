# pincer_webhook

HTTP webhook channel adapter for the Pincer AI agent framework.

Part of the [Pincer](https://github.com/manelsen/Pincer) AI agent framework.

## Installation

```elixir
def deps do
  [
    {:pincer_webhook, "~> 0.1"}
  ]
end
```

## Usage

Add to your `config.yaml`:

```yaml
channels:
  webhook:
    enabled: true
    port: 4000
    secret_env: WEBHOOK_SECRET
```

## License

MIT
