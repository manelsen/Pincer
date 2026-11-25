defmodule Pincer.Architecture.BoundaryExternalAppsTest do
  use ExUnit.Case, async: true

  @pincer_packages [
    :pincer_ports,
    :pincer_shared,
    :pincer_cli,
    :pincer_openai_compat,
    :pincer_anthropic,
    :pincer_google,
    :pincer_openai,
    :pincer_mistral,
    :pincer_groq,
    :pincer_minimax,
    :pincer_moonshot,
    :pincer_ollama,
    :pincer_openrouter,
    :pincer_deepseek,
    :pincer_qwen,
    :pincer_zhipu,
    :pincer_opencode_zen,
    :pincer_telegram,
    :pincer_webhook,
    :pincer_whatsapp,
    :pincer_line,
    :pincer_feishu,
    :pincer_dingtalk,
    :pincer_slack,
    :pincer_discord
  ]

  test "Pincer.Ports declares type: :strict" do
    opts = boundary_opts!("lib/pincer/ports.ex", [:Pincer, :Ports])
    assert Keyword.get(opts, :type) == :strict
  end

  test "Pincer.Utils declares check: [apps: ...] blocking forbidden external apps" do
    opts = boundary_opts!("lib/pincer/utils.ex", [:Pincer, :Utils])
    apps = opts |> Keyword.get(:check, []) |> Keyword.get(:apps, [])

    assert is_list(apps) and apps != [], "Pincer.Utils must declare check: [apps: [...]]"

    required_blocked = [:req, :exqlite, :mix, :plug, :bandit] ++ @pincer_packages

    Enum.each(required_blocked, fn app ->
      assert app in apps, "Expected Pincer.Utils check.apps to block #{inspect(app)}"
    end)

    refute :jason in apps
  end

  test "Pincer.Infra declares check: [apps: ...] blocking forbidden external apps" do
    opts = boundary_opts!("lib/pincer/infra.ex", [:Pincer, :Infra])
    apps = opts |> Keyword.get(:check, []) |> Keyword.get(:apps, [])

    assert is_list(apps) and apps != [], "Pincer.Infra must declare check: [apps: [...]]"

    required_blocked = [:req, :mix, :plug, :bandit] ++ @pincer_packages

    Enum.each(required_blocked, fn app ->
      assert app in apps, "Expected Pincer.Infra check.apps to block #{inspect(app)}"
    end)

    refute :exqlite in apps
    refute :yaml_elixir in apps
    refute :jason in apps
    refute :logger in apps
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
