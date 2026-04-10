# pincer_discord

Discord channel adapter for the Pincer AI agent framework.

Part of the [Pincer](https://github.com/manelsen/Pincer) AI agent framework.

## Installation

```elixir
def deps do
  [
    {:pincer_discord, "~> 0.1"}
  ]
end
```

## Usage

Add to your `config.yaml`:

```yaml
channels:
  discord:
    enabled: true
    token_env: DISCORD_BOT_TOKEN
```

## License

MIT
