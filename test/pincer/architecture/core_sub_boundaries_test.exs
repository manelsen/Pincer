defmodule Pincer.Architecture.CoreSubBoundariesTest do
  use ExUnit.Case, async: false

  alias Boundary.Mix.{CompilerState, View}

  @slices [
    Pincer.Core.Session,
    Pincer.Core.Project,
    Pincer.Core.Orchestration,
    Pincer.Core.Introspection,
    Pincer.Core.Skills,
    Pincer.Core.Executor,
    Pincer.Core.Memory,
    Pincer.Core.LLM,
    Pincer.Core.Graph
  ]

  setup_all do
    {:ok, _pid} = CompilerState.start_link()
    {:ok, view: View.build()}
  end

  test "domain slices enable inbound and outbound checks without reference exceptions", %{
    view: view
  } do
    for slice <- @slices do
      assert %{check: %{in: true, out: true}, dirty_xrefs: exceptions} = Boundary.get(view, slice)
      assert Enum.empty?(exceptions), "#{inspect(slice)} has reference exceptions"
    end
  end

  test "the boundary checker allows an exported sibling call and rejects a private one", %{
    view: view
  } do
    exported_call = %{
      from: Pincer.Core.Session.Server,
      from_function: {:handle_call, 3},
      to: Pincer.Core.Executor.PromptAssembly,
      type: :call,
      mode: :runtime,
      file: __ENV__.file,
      line: __ENV__.line
    }

    private_call = %{exported_call | to: Pincer.Core.Executor.Ctx}

    violations =
      for {:invalid_reference, violation} <- Boundary.errors(view, [exported_call, private_call]),
          do: violation

    assert [
             %{
               type: :not_exported,
               from_boundary: Pincer.Core.Session,
               to_boundary: Pincer.Core.Executor,
               reference: ^private_call
             }
           ] = violations
  end
end
