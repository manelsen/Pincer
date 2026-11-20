defmodule Pincer.Adapters.Tools.CodeSkeletonToolTest do
  use ExUnit.Case, async: true

  alias Pincer.Adapters.Tools.CodeSkeleton

  setup do
    base =
      Path.join(System.tmp_dir!(), "pincer_code_skel_#{System.unique_integer([:positive])}")

    ws = Path.join(base, "ws")
    outside = Path.join(base, "outside")
    File.mkdir_p!(Path.join(ws, "lib"))
    File.mkdir_p!(outside)

    File.write!(Path.join(ws, "lib/demo.ex"), """
    defmodule Demo do
      def hello(name) do
        secret_impl = "internal"
        {name, secret_impl}
      end
    end
    """)

    outside_file = Path.join(outside, "secret.ex")
    File.write!(outside_file, "defmodule Secret, do: def key, do: :top_secret\n")
    File.ln_s!(outside_file, Path.join(ws, "escape.ex"))

    on_exit(fn -> File.rm_rf!(base) end)

    {:ok, %{ws: ws, outside_file: outside_file, context: %{"workspace_path" => ws}}}
  end

  test "extracts skeleton for file inside workspace", %{context: ctx} do
    assert {:ok, skeleton} = CodeSkeleton.execute(%{"file_path" => "lib/demo.ex"}, ctx)
    assert skeleton =~ "defmodule Demo"
    assert skeleton =~ "def hello(name)"
    refute skeleton =~ "secret_impl"
  end

  test "rejects path traversal, outside absolute paths, and escaping symlinks", %{
    outside_file: outside_file,
    context: ctx
  } do
    for unsafe <- ["../outside/secret.ex", outside_file, "escape.ex"] do
      assert {:error, reason} = CodeSkeleton.execute(%{"file_path" => unsafe}, ctx)
      assert reason =~ "Access denied" or reason =~ "traversal" or reason =~ "outside"
    end
  end

  test "returns error for missing file or missing file_path", %{context: ctx} do
    assert {:error, _} = CodeSkeleton.execute(%{"file_path" => "lib/missing.ex"}, ctx)
    assert {:error, _} = CodeSkeleton.execute(%{}, ctx)
  end
end
