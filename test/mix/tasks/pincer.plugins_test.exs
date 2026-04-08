defmodule Mix.Tasks.Pincer.PluginsTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  describe "pincer.plugins list" do
    test "lista plugins descobertos em priv/plugins/" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Mix.Tasks.Pincer.Plugins.run(["list"])
        end)

      assert output =~ "telegram"
      assert output =~ "channel"
    end

    test "sem argumentos mostra ajuda" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Mix.Tasks.Pincer.Plugins.run([])
        end)

      assert output =~ "Usage" or output =~ "usage" or output =~ "list"
    end
  end
end
