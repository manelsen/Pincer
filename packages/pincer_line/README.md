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
    channel_access_token_env: LINE_CHANNEL_ACCESS_TOKEN
    channel_secret_env: LINE_CHANNEL_SECRET
```

## License

MIT
