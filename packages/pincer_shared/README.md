# pincer_shared

Shared runtime helpers (`Pincer.Channels.Shared.TokenCache` and `Pincer.Channels.Shared.WebhookVerifier`) for channel adapters in the [Pincer](https://github.com/manelsen/Pincer) AI agent framework.

`Pincer.Channels.Shared.Text` strips internal reasoning from responses and formats reasoning for HTML-capable channels. Both functions preserve `nil` and non-string values.

## Installation

```elixir
def deps do
  [
    {:pincer_shared, "~> 0.1"}
  ]
end
```

## License

MIT
