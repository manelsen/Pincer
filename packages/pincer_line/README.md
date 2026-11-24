# pincer_line

LINE Messaging API channel adapter for the Pincer AI agent framework.

Part of the [Pincer](https://github.com/manelsen/Pincer) AI agent framework.

## Installation

```elixir
def deps do
  [
    {:pincer_line, "~> 0.1"}
  ]
end
```

## Usage

Add to your `config.yaml`:

```yaml
channels:
  line:
    enabled: true
    token_env: LINE_CHANNEL_ACCESS_TOKEN
    secret_env: LINE_CHANNEL_SECRET
    webhook:
      enabled: true
      bind: 127.0.0.1
      port: 4011
      path: /webhooks/line
```

Point the LINE Messaging API webhook URL at `/webhooks/line` through an
HTTPS reverse proxy. The listener verifies `X-Line-Signature` with the
configured channel secret and is disabled unless that secret is present.

## License

MIT
