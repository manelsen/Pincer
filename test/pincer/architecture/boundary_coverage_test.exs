defmodule Pincer.Architecture.BoundaryCoverageTest do
  use ExUnit.Case, async: false

  alias Boundary.Mix.{CompilerState, View}

  @non_exporting_roots [
    Pincer.Channels,
    Pincer.LLM,
    Pincer.Application,
    Pincer.CLI,
    Pincer.Core.HookDispatcher
  ]

  @forbidden_calls [
    {Pincer.Core.Policy, Pincer.Adapters.Storage.SQLite, Pincer.Core, Pincer.Adapters},
    {Pincer.Ports.Storage, Pincer.Infra.SQLite, Pincer.Ports, Pincer.Infra},
    {Pincer.Plugin.Manifest, Pincer.Infra.Config, Pincer.Plugin, Pincer.Infra},
    {Pincer.LLM.Client, Pincer.Infra.Config, Pincer.LLM, Pincer.Infra},
    {Pincer.Channels.Factory, Pincer.Core.Policy, Pincer.Channels, Pincer.Core},
    {Pincer.Adapters.Storage.SQLite, Pincer.Channels.Factory, Pincer.Adapters, Pincer.Channels}
  ]

  setup_all do
    {:ok, _pid} = CompilerState.start_link()
    {:ok, view: View.build()}
  end

  test "non-exporting boundary roots compile with empty exports", %{view: view} do
    for root <- @non_exporting_roots do
      boundary = Boundary.get(view, root)
      assert boundary != nil, "Expected #{inspect(root)} to be registered in Boundary view"
      assert boundary.exports == [], "Expected #{inspect(root)} to have empty exports"
    end
  end

  test "Boundary.errors rejects forbidden cross-layer calls", %{view: view} do
    for {from_mod, to_mod, expected_from_boundary, expected_to_boundary} <- @forbidden_calls do
      ref = %{
        from: from_mod,
        from_function: {:call, 1},
        to: to_mod,
        type: :call,
        mode: :runtime,
        file: __ENV__.file,
        line: __ENV__.line
      }

      assert [
               {:invalid_reference,
                %{
                  from_boundary: ^expected_from_boundary,
                  to_boundary: ^expected_to_boundary,
                  reference: ^ref
                }}
             ] = Boundary.errors(view, [ref])
    end
  end

  test "Boundary.errors permits valid cross-layer calls", %{view: view} do
    allowed_refs = [
      %{
        from: Pincer.Core.Policy,
        from_function: {:check, 1},
        to: Pincer.Ports.Storage,
        type: :call,
        mode: :runtime,
        file: __ENV__.file,
        line: __ENV__.line
      },
      %{
        from: Pincer.Channels.Factory,
        from_function: {:start, 1},
        to: Pincer.Infra.Config,
        type: :call,
        mode: :runtime,
        file: __ENV__.file,
        line: __ENV__.line
      }
    ]

    assert Boundary.errors(view, allowed_refs) == []
  end
end
