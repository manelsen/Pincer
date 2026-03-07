defmodule Mix.Tasks.Pincer.ServerTest do
  use ExUnit.Case, async: true

  @template_path Path.expand("../../../infrastructure/systemd/pincer.service", __DIR__)

  test "systemd template lets systemd own graceful stop" do
    template = File.read!(@template_path)

    refute template =~ "ExecStop=/bin/kill -TERM $MAINPID"
  end

  test "systemd template starts the server task without bogus channel flags" do
    template = File.read!(@template_path)

    assert template =~ "ExecStart=/usr/bin/env mix pincer.server telegram"
    refute template =~ "--no-compile"
  end
end
