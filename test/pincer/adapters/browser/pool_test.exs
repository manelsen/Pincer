defmodule Pincer.Adapters.Browser.PoolTest do
  use ExUnit.Case, async: true

  alias Pincer.Adapters.Browser.Pool

  defp write_sidecar_script! do
    dir =
      Path.join(System.tmp_dir!(), "pincer_browser_pool_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    script = Path.join(dir, "sidecar.sh")

    File.write!(script, """
    while IFS= read -r line; do
      case "$line" in
        *'"cmd":"ping"'*)
          id=${line##*'"id":"'}
          id=${id%%'"'*}
          printf 'non-json sidecar line\\n'
          printf '{"id":"%s","ok":"pong_payload_longer_than_16_bytes_to_trigger_noeol"}\\n' "$id"
          ;;
        *'"cmd":"err"'*)
          id=${line##*'"id":"'}
          id=${id%%'"'*}
          printf '{"id":"%s","error":"boom"}\\n' "$id"
          ;;
        *'"cmd":"crash"'*)
          exit 1
          ;;
      esac
    done
    """)

    on_exit(fn -> File.rm_rf(dir) end)
    script
  end

  defp start_pool!(opts \\ []) do
    script = write_sidecar_script!()
    sh = System.find_executable("sh")

    pool_opts =
      Keyword.merge(
        [
          name: nil,
          executable: sh,
          args: [script],
          line_length: 16
        ],
        opts
      )

    start_supervised!({Pool, pool_opts})
  end

  test "reassembles {:noeol, chunk} and {:eol, chunk} port frames into complete JSON responses" do
    pid = start_pool!()

    assert {:ok, "pong_payload_longer_than_16_bytes_to_trigger_noeol"} =
             GenServer.call(pid, {:cmd, "sess1", "ping", %{}})
  end

  test "returns {:error, reason} on error JSON payload and continues ignoring non-JSON lines" do
    pid = start_pool!()

    assert {:error, "boom"} = GenServer.call(pid, {:cmd, "sess1", "err", %{}})

    assert {:ok, "pong_payload_longer_than_16_bytes_to_trigger_noeol"} =
             GenServer.call(pid, {:cmd, "sess1", "ping", %{}})
  end

  test "fails pending callers with {:error, :sidecar_crashed} and resets buffer on port exit" do
    pid = start_pool!()

    assert {:error, :sidecar_crashed} = GenServer.call(pid, {:cmd, "sess1", "crash", %{}})

    # Subsequent calls transparently restart the sidecar port cleanly
    assert {:ok, "pong_payload_longer_than_16_bytes_to_trigger_noeol"} =
             GenServer.call(pid, {:cmd, "sess1", "ping", %{}})
  end
end
