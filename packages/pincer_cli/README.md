# pincer_cli

Command-line interface channel adapter for the [Pincer](https://github.com/manelsen/Pincer) AI agent framework.

## Installation

```elixir
def deps do
  [
    {:pincer_cli, "~> 0.2"}
  ]
end
```

## Usage

Enable in `config.yaml`:

```yaml
channels:
  cli:
    enabled: true
    adapter: "Pincer.Channels.CLI"
```

Start an interactive session with `mix pincer.chat`.

## License

MIT
