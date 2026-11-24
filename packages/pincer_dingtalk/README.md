# pincer_dingtalk

DingTalk channel adapter for the Pincer AI agent framework.

Part of the [Pincer](https://github.com/manelsen/Pincer) AI agent framework.

## Installation

```elixir
def deps do
  [
    {:pincer_dingtalk, "~> 0.1"}
  ]
end
```

## Usage

Add to your `config.yaml`:

```yaml
channels:
  dingtalk:
    enabled: true
    client_id_env: DINGTALK_CLIENT_ID
    client_secret_env: DINGTALK_CLIENT_SECRET
```

## License

MIT
