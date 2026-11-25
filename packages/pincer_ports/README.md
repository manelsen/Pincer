# pincer_ports

Shared contracts for Pincer's channels and LLM providers. The `PincerPorts` boundary exports these contracts and their shared data types under `PincerPorts.*`.

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
  @behaviour PincerPorts.LLM.Provider
  # implement callbacks...
end
```

## License

MIT
