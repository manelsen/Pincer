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
    webhook:
      enabled: true
      bind: 127.0.0.1
      port: 4010
      path: /webhooks/feishu
      encrypt_key_env: FEISHU_ENCRYPT_KEY
      verification_token_env: FEISHU_VERIFICATION_TOKEN
```

Set `FEISHU_ENCRYPT_KEY` to the Encrypt Key from the Feishu app's
Event Subscription settings. The listener is disabled unless the key is
present, so an unauthenticated endpoint is never exposed.

Expose the path through your reverse proxy with HTTPS and point the Feishu
event subscription URL at it. Pincer answers `url_verification` challenges,
verifies signatures, decrypts encrypted payloads, and routes
`im.message.receive_v1` events to per-chat sessions.

## License

MIT
