defmodule Pincer.BoundaryExportsTest do
  use ExUnit.Case, async: true

  @boundary_files [
    {"lib/pincer/core.ex", [:Pincer, :Core]},
    {"lib/pincer/infra.ex", [:Pincer, :Infra]},
    {"lib/pincer/ports.ex", [:Pincer, :Ports]}
  ]

  test "owner boundary exports use relative aliases" do
    Enum.each(@boundary_files, fn {file, owner_alias} ->
      exports = boundary_exports(file)
      assert exports != [], "#{file} should declare exports for this regression test"

      Enum.each(exports, fn export_alias ->
        refute absolute_owner_alias?(export_alias, owner_alias),
               """
               #{file} exports #{Macro.to_string(export_alias)} with owner-prefixed alias.
               Use relative aliases inside `exports` for #{Enum.join(owner_alias, ".")}.
               """
      end)
    end)
  end

  test "mix tasks are manually classified to Pincer.Mix boundary" do
    mix_boundary_source = File.read!("lib/pincer.ex")

    assert mix_boundary_source =~ "defmodule Pincer.Mix do"
    assert mix_boundary_source =~ "use Boundary"
    assert mix_boundary_source =~ "top_level?: true"
    assert mix_boundary_source =~ "check: [in: false, out: false]"

    task_files = [
      "lib/mix/tasks/pincer.chat.ex",
      "lib/mix/tasks/pincer.doctor.ex",
      "lib/mix/tasks/pincer.onboard.ex",
      "lib/mix/tasks/pincer.security_audit.ex",
      "lib/mix/tasks/pincer.server.ex"
    ]

    Enum.each(task_files, fn file ->
      source = File.read!(file)
      assert source =~ "use Boundary, classify_to: Pincer.Mix"
    end)
  end

  test "web decoder module is namespaced inside adapters boundary" do
    source = File.read!("lib/pincer/tools/web.ex")

    assert source =~ "defmodule Pincer.Adapters.Tools.Web.HtmlEntities do"
    refute source =~ "defmodule HtmlEntities do"
  end

  defp boundary_exports(file) do
    file
    |> File.read!()
    |> Code.string_to_quoted!(file: file)
    |> collect_boundary_exports()
  end

  defp collect_boundary_exports(ast) do
    {_ast, exports} =
      Macro.prewalk(ast, [], fn
        {:use, _, [{:__aliases__, _, [:Boundary]}, opts]} = node, acc when is_list(opts) ->
          {node, acc ++ Keyword.get(opts, :exports, [])}

        node, acc ->
          {node, acc}
      end)

    exports
  end

  defp absolute_owner_alias?({:__aliases__, _, parts}, owner_parts) do
    Enum.take(parts, length(owner_parts)) == owner_parts
  end

  defp absolute_owner_alias?(_, _), do: false
end
