# pincer_whatsapp

Isolated WhatsApp channel adapter and embedded Go `whatsapp_bridge` compiler for the [Pincer](https://github.com/manelsen/Pincer) AI agent framework.

## Installation

Requires Go `1.21+` in `PATH` when compiling the native `priv/whatsapp_bridge` sidecar binary:

```elixir
def deps do
  [
    {:pincer_whatsapp, "~> 0.2"}
  ]
end
```

During compilation, `Mix.Tasks.Compile.WhatsappBridge` builds `priv/src/whatsapp_bridge` into `priv/whatsapp_bridge` without bundling any precompiled binary in source control or the Hex tarball.

## Usage

Add to your `config.yaml`:

```yaml
channels:
  whatsapp:
    enabled: true
    adapter: "Pincer.Channels.WhatsApp"
    dm_policy:
      mode: "pairing"
    bridge:
      auth_dir: "sessions/whatsapp"
      qr_ascii: true
      qr_ascii_small: true
      pairing_phone: ""
```

## License

MIT
