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
    app_key_env: DINGTALK_APP_KEY
    app_secret_env: DINGTALK_APP_SECRET
```

## License

MIT
