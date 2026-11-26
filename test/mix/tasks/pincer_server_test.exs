defmodule Mix.Tasks.Pincer.ServerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @template_path Path.expand("../../../infrastructure/systemd/pincer.service", __DIR__)

  setup do
    previous = Application.get_env(:elixir, :ansi_enabled)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:elixir, :ansi_enabled)
      else
        Application.put_env(:elixir, :ansi_enabled, previous)
      end
    end)

    :ok
  end

  test "systemd template lets systemd own graceful stop" do
    template = File.read!(@template_path)

    refute template =~ "ExecStop=/bin/kill -TERM $MAINPID"
  end

  test "systemd template starts the server task without bogus channel flags" do
    template = File.read!(@template_path)

    assert template =~ "ExecStart=/usr/bin/env mix pincer.server telegram"
    refute template =~ "--no-compile"
  end

  test "unknown service command respects Pincer.Utils.ANSI enabled state" do
    Application.put_env(:elixir, :ansi_enabled, true)

    colored =
      capture_io(fn ->
        Mix.Tasks.Pincer.Server.run(["service", "bogus"])
      end)

    assert colored =~ "\e[31mUnknown service command: bogus\e[0m"
    assert colored =~ "Usage: mix pincer.server service"

    Application.put_env(:elixir, :ansi_enabled, false)

    plain =
      capture_io(fn ->
        Mix.Tasks.Pincer.Server.run(["service", "bogus"])
      end)

    assert plain =~ "Unknown service command: bogus"
    refute plain =~ "\e["
  end
end
