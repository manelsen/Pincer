# pincer_whatsapp

WhatsApp Business API channel adapter for the Pincer AI agent framework.

Part of the [Pincer](https://github.com/manelsen/Pincer) AI agent framework.

## Installation

```elixir
def deps do
  [
    {:pincer_whatsapp, "~> 0.1"}
  ]
end
```

## Usage

Add to your `config.yaml`:

```yaml
channels:
  whatsapp:
    enabled: true
    phone_number_id_env: WHATSAPP_PHONE_NUMBER_ID
    access_token_env: WHATSAPP_ACCESS_TOKEN
```

## License

MIT
