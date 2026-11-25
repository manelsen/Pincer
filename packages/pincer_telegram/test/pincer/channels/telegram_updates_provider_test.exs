defmodule Pincer.Channels.Telegram.UpdatesProviderTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  import Mox

  alias Pincer.Channels.Telegram.APIMock
  alias Pincer.Channels.Telegram.UpdatesProvider

  defmodule TestChannelPolicy do
    def emit_error(_reason, _metadata), do: :ok
    def classify(:transient, _context), do: true
  end

  setup do
    settings = [telegram_api: APIMock, channel_policy_adapter: TestChannelPolicy]
    previous = Enum.map(settings, fn {key, _} -> {key, Application.fetch_env(:pincer, key)} end)
    Application.put_all_env(pincer: settings)

    offset_path =
      Path.join(
        System.tmp_dir!(),
        "pincer_telegram_offset_#{System.unique_integer([:positive])}.txt"
      )

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, adapter}} -> Application.put_env(:pincer, key, adapter)
        {key, :error} -> Application.delete_env(:pincer, key)
      end)

      File.rm(offset_path)
    end)

    verify_on_exit!()
    {:ok, offset_path: offset_path}
  end

  test "loads persisted offset on boot and persists the next offset after polling", %{
    offset_path: offset_path
  } do
    File.write!(offset_path, "42\n")

    APIMock
    |> expect(:get_updates, fn opts ->
      assert opts[:offset] == 42
      assert opts[:timeout] == 5
      {:ok, [%{update_id: 44}]}
    end)

    pid = start_supervised!({UpdatesProvider, [offset_path: offset_path]})
    allow(APIMock, self(), pid)

    assert %{offset: 42} = :sys.get_state(pid)

    send(pid, :poll)

    assert %{offset: 45} = :sys.get_state(pid)
    assert File.read!(offset_path) == "45\n"
  end

  # SPR-047: flood of malformed callbacks must not crash the poller
  test "process stays alive after flood of malformed callback_query updates", %{
    offset_path: offset_path
  } do
    # Build 30 malformed callback_query updates (no message, no chat_id, no data)
    malformed_updates =
      for i <- 1..30 do
        %{
          update_id: 1000 + i,
          callback_query: %{id: "cb_#{i}", from: %{id: 99}, data: nil, message: nil}
        }
      end

    APIMock
    |> expect(:get_updates, fn _opts -> {:ok, malformed_updates} end)

    pid = start_supervised!({UpdatesProvider, [offset_path: offset_path]})
    allow(APIMock, self(), pid)

    log =
      capture_log(fn ->
        send(pid, :poll)
        _ = :sys.get_state(pid)
      end)

    assert Process.alive?(pid), "UpdatesProvider must remain alive after malformed callbacks"
    assert log =~ "Ignoring malformed callback query"
    # Offset should advance past the last update
    assert %{offset: 1031} = :sys.get_state(pid)
  end

  # SPR-047: polling error increments failure counter, success resets it
  test "failure counter increments on error and resets on success", %{
    offset_path: offset_path
  } do
    APIMock
    |> expect(:get_updates, fn _opts -> {:error, :timeout} end)
    |> expect(:get_updates, fn _opts -> {:ok, [%{update_id: 10}]} end)

    pid = start_supervised!({UpdatesProvider, [offset_path: offset_path]})
    allow(APIMock, self(), pid)

    send(pid, :poll)
    assert %{failures: 1} = :sys.get_state(pid)

    send(pid, :poll)
    assert %{failures: 0} = :sys.get_state(pid)
  end

  # SPR-047: offset does not advance when poll returns an error
  test "offset unchanged when polling returns error", %{offset_path: offset_path} do
    File.write!(offset_path, "10\n")

    APIMock
    |> expect(:get_updates, fn _opts -> {:error, :econnrefused} end)

    pid = start_supervised!({UpdatesProvider, [offset_path: offset_path]})
    allow(APIMock, self(), pid)

    send(pid, :poll)

    assert %{offset: 10} = :sys.get_state(pid)
  end
end
