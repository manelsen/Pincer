# pincer_dingtalk

DingTalk channel adapter for the Pincer AI agent framework.

Part of the [Pincer](https://github.com/manelsen/Pincer) AI agent framework.

## Installation

```elixir
def deps do
  [
    {:pincer_dingtalk, "~> 0.2"}
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
    webhook:
      enabled: true
      bind: 127.0.0.1
      port: 4012
      path: /webhooks/dingtalk
      signing_secret_env: DINGTALK_SIGNING_SECRET
```

Point the DingTalk robot event subscription at `/webhooks/dingtalk` through
an HTTPS reverse proxy. The listener verifies the timestamp signature with
the configured signing secret and is disabled unless that secret is present.
Encrypted DingTalk event bodies are rejected explicitly; disable body
encryption in the robot event subscription for now.

## License

MIT
