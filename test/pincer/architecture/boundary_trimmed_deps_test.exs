defmodule Pincer.Architecture.BoundaryTrimmedDepsTest do
  use ExUnit.Case, async: false

  setup do
    previous = Application.get_env(:pincer, :cli_channel_adapter)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:pincer, :cli_channel_adapter)
      else
        Application.put_env(:pincer, :cli_channel_adapter, previous)
      end
    end)

    :ok
  end

  test "Pincer.Plugin boundary has no deps" do
    opts = extract_boundary_opts!("lib/pincer/plugin.ex")
    assert dep_names(opts) == []
  end

  test "Pincer.LLM boundary trims unused Pincer.Infra dep" do
    deps = "lib/pincer/llm.ex" |> extract_boundary_opts!() |> dep_names()

    assert Enum.sort(deps) == Enum.sort([Pincer.Core, Pincer.Ports, Pincer.Utils])
    refute Pincer.Infra in deps
  end

  test "Pincer.Channels boundary trims unused deps to Infra, Plugin, and PincerPorts" do
    deps = "lib/pincer/channels.ex" |> extract_boundary_opts!() |> dep_names()

    assert Enum.sort(deps) == Enum.sort([Pincer.Infra, Pincer.Plugin, PincerPorts])
    refute Pincer.Core in deps
    refute Pincer.Ports in deps
    refute Pincer.Utils in deps
  end

  test "Pincer.CLI boundary depends on Core, Plugin, and Utils instead of Channels" do
    deps = "lib/pincer/cli.ex" |> extract_boundary_opts!() |> dep_names()

    assert Enum.sort(deps) == Enum.sort([Pincer.Core, Pincer.Plugin, Pincer.Utils])
    refute Pincer.Channels in deps
  end

  test "Pincer.CLI resolves its channel backend dynamically via backend_name/0" do
    Application.delete_env(:pincer, :cli_channel_adapter)
    assert Pincer.CLI.backend_name() == Pincer.Channels.CLI

    Application.put_env(:pincer, :cli_channel_adapter, __MODULE__.FakeCLIAdapter)
    assert Pincer.CLI.backend_name() == __MODULE__.FakeCLIAdapter
  end

  defp extract_boundary_opts!(file) do
    ast =
      file
      |> File.read!()
      |> Code.string_to_quoted!(file: file)

    {_ast, found} =
      Macro.prewalk(ast, nil, fn
        {:use, _, [{:__aliases__, _, [:Boundary]}]} = node, nil ->
          {node, []}

        {:use, _, [{:__aliases__, _, [:Boundary]}, opts]} = node, nil when is_list(opts) ->
          {node, opts}

        node, acc ->
          {node, acc}
      end)

    assert is_list(found), "Expected #{file} to declare `use Boundary`"
    found
  end

  defp dep_names(opts) do
    opts
    |> Keyword.get(:deps, [])
    |> Enum.map(fn
      {:__aliases__, _, parts} -> Module.concat(parts)
      other -> other
    end)
  end
end
