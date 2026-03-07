defmodule Pincer.Channels.Telegram.UpdatesProviderTest do
  use ExUnit.Case, async: false
  import Mox

  alias Pincer.Channels.Telegram.APIMock
  alias Pincer.Channels.Telegram.UpdatesProvider

  setup do
    Application.put_env(:pincer, :telegram_api, APIMock)

    offset_path =
      Path.join(
        System.tmp_dir!(),
        "pincer_telegram_offset_#{System.unique_integer([:positive])}.txt"
      )

    on_exit(fn ->
      Application.put_env(:pincer, :telegram_api, Pincer.Channels.TestAdapter)
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
    Process.sleep(50)

    assert %{offset: 45} = :sys.get_state(pid)
    assert File.read!(offset_path) == "45\n"
  end
end
