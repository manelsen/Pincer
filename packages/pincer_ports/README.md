# pincer_ports

Port behaviours and contracts for the Pincer AI agent framework — this is the foundational package that defines the `Behaviour` interfaces (LLM, Channel, Storage, Tool, Cron, etc.) that all other Pincer adapters implement.

Part of the [Pincer](https://github.com/manelsen/Pincer) AI agent framework.

## Installation

```elixir
def deps do
  [
    {:pincer_ports, "~> 0.1"}
  ]
end
```

## Usage

`pincer_ports` is a dependency of every Pincer adapter package. It defines no runtime processes of its own. Reference it directly only if you are building a custom adapter:

```elixir
defmodule MyLLM do
  @behaviour Pincer.Ports.LLM
  # implement callbacks...
end
```

## License

MIT
