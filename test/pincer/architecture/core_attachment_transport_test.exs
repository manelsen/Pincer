defmodule Pincer.Architecture.CoreAttachmentTransportTest do
  use ExUnit.Case, async: true

  test "Core attachment handling consumes the port without transport dependencies" do
    paths = [
      "lib/pincer/core/executor/attachments.ex",
      "lib/pincer/core/session/history.ex"
    ]

    for path <- paths do
      source = File.read!(path)

      refute source =~ ~r{telegram://|api\.telegram\.org|:telegex|\bReq\b},
             "#{path} depends on attachment transport"

      assert source =~ "Attachments.fetch"
    end
  end
end
