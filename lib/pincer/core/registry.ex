defmodule Pincer.Core.Registry do
  @moduledoc """
  Parameterized process registry supporting both cluster-wide (`:horde`) and
  node-local (`:local`) unique-key registries.
  """

  @type backend :: :horde | :local

  @doc """
  Returns a supervisor child specification for a unique-key registry.

  ## Options

    * `:name` (required) — registered name of the registry
    * `:backend` — `:horde` (default) or `:local`
    * `:keys` — defaults to `:unique`
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) when is_list(opts) do
    _name = Keyword.fetch!(opts, :name)
    {backend, registry_opts} = Keyword.pop(opts, :backend, :horde)
    registry_opts = Keyword.put_new(registry_opts, :keys, :unique)

    case backend do
      :horde -> Horde.Registry.child_spec(registry_opts)
      :local -> Registry.child_spec(registry_opts)
      other -> raise ArgumentError, "unsupported registry backend: #{inspect(other)}"
    end
  end

  @doc """
  Returns a `{:via, ...}` tuple for process registration.
  """
  @spec via_tuple(atom(), term(), backend()) ::
          {:via, Horde.Registry | Registry, {atom(), term()}}
  def via_tuple(registry, key, backend \\ :horde)

  def via_tuple(registry, key, :horde) when is_atom(registry),
    do: {:via, Horde.Registry, {registry, key}}

  def via_tuple(registry, key, :local) when is_atom(registry),
    do: {:via, Registry, {registry, key}}

  def via_tuple(_registry, _key, other),
    do: raise(ArgumentError, "unsupported registry backend: #{inspect(other)}")

  @doc """
  Looks up a process by `key` in `registry`.
  """
  @spec lookup(atom(), term(), backend()) :: [{pid(), term()}]
  def lookup(registry, key, backend \\ :horde)

  def lookup(registry, key, :horde) when is_atom(registry),
    do: Horde.Registry.lookup(registry, key)

  def lookup(registry, key, :local) when is_atom(registry),
    do: Registry.lookup(registry, key)

  def lookup(_registry, _key, other),
    do: raise(ArgumentError, "unsupported registry backend: #{inspect(other)}")
end
