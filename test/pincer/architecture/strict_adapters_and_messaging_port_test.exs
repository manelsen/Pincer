defmodule Pincer.Architecture.StrictAdaptersAndMessagingPortTest do
  use ExUnit.Case, async: true

  @adapter_boundaries [
    {"lib/pincer/adapters.ex", [:Pincer, :Adapters]},
    {"lib/pincer/adapters/tools.ex", [:Pincer, :Adapters, :Tools]},
    {"lib/pincer/adapters/connectors.ex", [:Pincer, :Adapters, :Connectors]},
    {"lib/pincer/adapters/health.ex", [:Pincer, :Adapters, :Health]}
  ]

  test "Pincer.Adapters and its sub-boundaries declare type: :strict" do
    for {file, module_parts} <- @adapter_boundaries do
      opts = boundary_opts!(file, module_parts)

      assert Keyword.get(opts, :type) == :strict,
             "Expected #{Enum.join(module_parts, ".")} in #{file} to declare type: :strict"
    end
  end

  test "Pincer.Ports does not include Pincer.Infra in deps (only PincerPorts)" do
    opts = boundary_opts!("lib/pincer/ports.ex", [:Pincer, :Ports])
    deps = opts |> Keyword.get(:deps, []) |> Enum.map(&Macro.to_string/1)

    refute "Pincer.Infra" in deps
    assert deps == ["PincerPorts"]
  end

  test "Pincer.Adapters.Messaging.PubSub implements PincerPorts.Messaging and OutboundMessaging is removed" do
    refute File.exists?("lib/pincer/channels/outbound_messaging.ex")
    refute Code.ensure_loaded?(Pincer.Channels.OutboundMessaging)

    Code.ensure_loaded!(Pincer.Adapters.Messaging.PubSub)
    behaviours = Pincer.Adapters.Messaging.PubSub.__info__(:attributes)[:behaviour] || []
    assert PincerPorts.Messaging in behaviours
  end

  defp boundary_opts!(file, expected_module_parts) do
    ast = file |> File.read!() |> Code.string_to_quoted!(file: file)

    {_ast, found} =
      Macro.prewalk(ast, nil, fn
        {:defmodule, _, [{:__aliases__, _, ^expected_module_parts}, [do: body]]} = node, _acc ->
          {node, extract_boundary_opts(body)}

        node, acc ->
          {node, acc}
      end)

    assert is_list(found),
           "Expected #{Enum.join(expected_module_parts, ".")} in #{file} to declare `use Boundary, opts`"

    found
  end

  defp extract_boundary_opts(body) do
    {_ast, opts} =
      Macro.prewalk(body, nil, fn
        {:use, _, [{:__aliases__, _, [:Boundary]}, opts]} = node, _acc when is_list(opts) ->
          {node, opts}

        node, acc ->
          {node, acc}
      end)

    opts
  end
end
