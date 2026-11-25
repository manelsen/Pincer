defmodule Pincer.Scripts.BuildSqliteVecTest do
  use ExUnit.Case, async: true

  @script_path Path.expand("../../../scripts/build_sqlite_vec.sh", __DIR__)

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "pincer_build_sqlite_vec_test_#{System.unique_integer([:positive])}"
      )

    bin_dir = Path.join(tmp_dir, "bin")
    build_dir = Path.join(tmp_dir, "build")
    out_dir = Path.join(tmp_dir, "out")
    make_log = Path.join(tmp_dir, "make.log")

    File.mkdir_p!(bin_dir)
    File.mkdir_p!(Path.join(build_dir, ".git"))
    File.mkdir_p!(out_dir)

    write_executable!(Path.join(bin_dir, "git"), """
    #!/usr/bin/env bash
    echo "unexpected git invocation: $*" >&2
    exit 1
    """)

    write_executable!(Path.join(bin_dir, "cc"), """
    #!/usr/bin/env bash
    exit 0
    """)

    write_executable!(Path.join(bin_dir, "make"), """
    #!/usr/bin/env bash
    set -euo pipefail
    echo "$*" >> "${FAKE_MAKE_LOG:?}"
    target_dir=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -C)
          target_dir="$2"
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done
    if [[ "${FAKE_MAKE_EMIT:-none}" != "none" ]]; then
      mkdir -p "$target_dir/dist"
      printf 'built-%s' "$FAKE_MAKE_EMIT" > "$target_dir/dist/$FAKE_MAKE_EMIT"
    fi
    """)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    {:ok, bin_dir: bin_dir, build_dir: build_dir, out_dir: out_dir, make_log: make_log}
  end

  test "script passes bash syntax check" do
    {output, status} = System.cmd("bash", ["-n", @script_path], stderr_to_stdout: true)
    assert status == 0, "Expected bash -n to exit 0, got #{status}: #{output}"
  end

  describe "when SQLITE_VEC_UNAME_S=Darwin" do
    test "builds and writes vec0.dylib when make emits dist/vec0.dylib", ctx do
      {output, status} = run_script(ctx, uname_s: "Darwin", make_emit: "vec0.dylib")

      assert status == 0, "Expected exit 0, got #{status}: #{output}"
      assert File.read!(Path.join(ctx.out_dir, "vec0.dylib")) == "built-vec0.dylib"
      refute File.exists?(Path.join(ctx.out_dir, "vec0.so"))
    end

    test "builds and writes vec0.dylib when make emits dist/vec0.so", ctx do
      {output, status} = run_script(ctx, uname_s: "Darwin", make_emit: "vec0.so")

      assert status == 0, "Expected exit 0, got #{status}: #{output}"
      assert File.read!(Path.join(ctx.out_dir, "vec0.dylib")) == "built-vec0.so"
      refute File.exists?(Path.join(ctx.out_dir, "vec0.so"))
    end

    test "skips rebuild when vec0.dylib already exists without --force", ctx do
      dylib_path = Path.join(ctx.out_dir, "vec0.dylib")
      File.write!(dylib_path, "existing-dylib")

      {output, status} = run_script(ctx, uname_s: "Darwin", make_emit: "vec0.dylib")

      assert status == 0, "Expected exit 0, got #{status}: #{output}"
      assert output =~ "already built at #{dylib_path}"
      assert File.read!(dylib_path) == "existing-dylib"
      refute File.exists?(ctx.make_log)
    end

    test "rebuilds vec0.dylib when --force is passed", ctx do
      dylib_path = Path.join(ctx.out_dir, "vec0.dylib")
      File.write!(dylib_path, "existing-dylib")

      {output, status} =
        run_script(ctx, uname_s: "Darwin", make_emit: "vec0.dylib", args: ["--force"])

      assert status == 0, "Expected exit 0, got #{status}: #{output}"
      assert File.read!(dylib_path) == "built-vec0.dylib"
      assert File.exists?(ctx.make_log)
    end
  end

  describe "when SQLITE_VEC_UNAME_S=Linux" do
    test "builds and writes vec0.so", ctx do
      {output, status} = run_script(ctx, uname_s: "Linux", make_emit: "vec0.so")

      assert status == 0, "Expected exit 0, got #{status}: #{output}"
      assert File.read!(Path.join(ctx.out_dir, "vec0.so")) == "built-vec0.so"
      refute File.exists?(Path.join(ctx.out_dir, "vec0.dylib"))
    end
  end

  test "fails with a clear error when make produces no loadable output", ctx do
    {output, status} = run_script(ctx, uname_s: "Darwin", make_emit: "none")

    assert status != 0
    assert output =~ "no loadable"
  end

  defp run_script(ctx, opts) do
    uname_s = Keyword.fetch!(opts, :uname_s)
    make_emit = Keyword.fetch!(opts, :make_emit)
    args = Keyword.get(opts, :args, [])

    env = [
      {"PATH", "#{ctx.bin_dir}:#{System.get_env("PATH")}"},
      {"SQLITE_VEC_BUILD_DIR", ctx.build_dir},
      {"SQLITE_VEC_OUT_DIR", ctx.out_dir},
      {"SQLITE_VEC_UNAME_S", uname_s},
      {"FAKE_MAKE_EMIT", make_emit},
      {"FAKE_MAKE_LOG", ctx.make_log}
    ]

    System.cmd("bash", [@script_path | args], env: env, stderr_to_stdout: true)
  end

  defp write_executable!(path, content) do
    File.write!(path, content)
    File.chmod!(path, 0o755)
  end
end
