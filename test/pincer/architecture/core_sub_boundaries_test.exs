defmodule Pincer.Architecture.CoreSubBoundariesTest do
  use ExUnit.Case, async: true

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

  test "domain slices declare boundaries and enforce cross-slice references" do
    missing =
      Enum.reject(@slices, fn slice ->
        Code.ensure_loaded?(slice) and
          match?([%{app: :pincer, opts: _}], slice.__info__(:attributes)[Boundary])
      end)

    assert missing == []

    for slice <- @slices do
      [%{opts: opts}] = slice.__info__(:attributes)[Boundary]
      assert Keyword.get(opts, :dirty_xrefs, []) == []
      assert opts |> Keyword.get(:check, []) |> Keyword.get(:out, true)
    end
  end
end
