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
    adapter: "Pincer.Channels.Webhook"
    token_env: "PINCER_WEBHOOK_TOKEN"
    port: 4000
    bind: "127.0.0.1"
    path: "/webhook/message"
    max_body_bytes: 1048576
```

Deliveries are `POST` requests to `path` (`/webhook` is also accepted as an
alias) with a JSON body and the token in either the `x-pincer-token` header or
the `authorization` header (`Bearer <token>` or the raw token).

| key | default | description |
|---|---|---|
| `port` | `4000` | HTTP listen port; `0` selects an ephemeral port |
| `bind` | `"127.0.0.1"` | Bind address; invalid values fail startup loudly |
| `path` | `"/webhook/message"` | POST path; `/webhook` is an alias |
| `max_body_bytes` | `1048576` | Hard request body cap, checked before JSON decoding |
| `token_env` | required | Environment variable holding the authentication token |

Responses are JSON: `202` accepted, `200` duplicate, `401` unauthorized,
`415` unsupported media type, `413` payload too large, `422` invalid payload,
`503` channel unavailable, and `500` for unexpected ingestion failures.

The listener fails closed: if `token_env` is unset or empty, neither the
channel nor its HTTP listener starts, and no port is bound.

## License

MIT
