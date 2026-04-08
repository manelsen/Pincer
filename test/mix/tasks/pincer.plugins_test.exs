defmodule Mix.Tasks.Pincer.PluginsTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Pincer.Plugins

  @config_with_disabled """
  channels:
    telegram:
      adapter: "Pincer.Channels.Telegram"
      enabled: false
      token_env: "TELEGRAM_BOT_TOKEN"
    discord:
      adapter: "Pincer.Channels.Discord"
      enabled: false
  other_section:
    key: value
  """

  @config_without_enabled """
  channels:
    telegram:
      adapter: "Pincer.Channels.Telegram"
      token_env: "TELEGRAM_BOT_TOKEN"
    discord:
      adapter: "Pincer.Channels.Discord"
      enabled: false
  """

  describe "pincer.plugins list" do
    test "lista plugins descobertos em priv/plugins/" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Plugins.run(["list"])
        end)

      assert output =~ "telegram"
      assert output =~ "channel"
    end

    test "sem argumentos mostra ajuda" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Plugins.run([])
        end)

      assert output =~ "Usage" or output =~ "usage" or output =~ "list"
    end
  end

  describe "pincer.plugins enable" do
    test "ativa canal com enabled: false no config.yaml" do
      path = write_tmp_config(@config_with_disabled)

      ExUnit.CaptureIO.capture_io(fn ->
        Plugins.run(["enable", "telegram", "--config", path])
      end)

      content = File.read!(path)
      assert channel_enabled?(content, "telegram")
    end

    test "não altera outros canais ao habilitar um" do
      path = write_tmp_config(@config_with_disabled)

      ExUnit.CaptureIO.capture_io(fn ->
        Plugins.run(["enable", "telegram", "--config", path])
      end)

      content = File.read!(path)
      refute channel_enabled?(content, "discord")
    end

    test "injeta enabled: true quando a chave está ausente" do
      path = write_tmp_config(@config_without_enabled)

      ExUnit.CaptureIO.capture_io(fn ->
        Plugins.run(["enable", "telegram", "--config", path])
      end)

      content = File.read!(path)
      assert channel_enabled?(content, "telegram")
    end

    test "retorna erro para canal não encontrado no config" do
      path = write_tmp_config(@config_with_disabled)

      output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          Plugins.run(["enable", "nonexistent", "--config", path])
        end)

      assert output =~ "not found" or output =~ "não encontrado"
    end
  end

  @config_with_enabled """
  channels:
    telegram:
      adapter: "Pincer.Channels.Telegram"
      enabled: true
      token_env: "TELEGRAM_BOT_TOKEN"
    discord:
      adapter: "Pincer.Channels.Discord"
      enabled: true
  other_section:
    key: value
  """

  describe "pincer.plugins disable" do
    test "desativa canal com enabled: true no config.yaml" do
      path = write_tmp_config(@config_with_enabled)

      ExUnit.CaptureIO.capture_io(fn ->
        Plugins.run(["disable", "telegram", "--config", path])
      end)

      content = File.read!(path)
      refute channel_enabled?(content, "telegram")
    end

    test "não altera outros canais ao desabilitar um" do
      path = write_tmp_config(@config_with_enabled)

      ExUnit.CaptureIO.capture_io(fn ->
        Plugins.run(["disable", "telegram", "--config", path])
      end)

      content = File.read!(path)
      assert channel_enabled?(content, "discord")
    end

    test "injeta enabled: false quando a chave está ausente" do
      path = write_tmp_config(@config_without_enabled)

      ExUnit.CaptureIO.capture_io(fn ->
        Plugins.run(["disable", "discord", "--config", path])
      end)

      content = File.read!(path)
      refute channel_enabled?(content, "discord")
    end

    test "retorna erro para canal não encontrado no config" do
      path = write_tmp_config(@config_with_enabled)

      output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          Plugins.run(["disable", "nonexistent", "--config", path])
        end)

      assert output =~ "not found" or output =~ "não encontrado"
    end
  end

  describe "pincer.plugins status" do
    test "mostra todos os plugins instalados com estado enabled/disabled" do
      path = write_tmp_config(@config_with_disabled)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Plugins.run(["status", "--config", path])
        end)

      # telegram is installed (manifest exists) and disabled in config
      assert output =~ "telegram"
      assert output =~ ~r/disabled|✗|off/i or output =~ "false"
    end

    test "marca canal como enabled quando habilitado no config" do
      path = write_tmp_config(@config_with_enabled)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Plugins.run(["status", "--config", path])
        end)

      assert output =~ "telegram"
      assert output =~ ~r/enabled|✓|on/i or output =~ "true"
    end

    test "lista todos os 9 canais bundled" do
      path = write_tmp_config(@config_with_disabled)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Plugins.run(["status", "--config", path])
        end)

      for channel <- ~w(telegram discord cli webhook line feishu whatsapp dingtalk slack) do
        assert output =~ channel, "Expected to find '#{channel}' in status output"
      end
    end
  end

  describe "pincer.plugins install" do
    test "informa que plugin bundled já está instalado" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Plugins.run(["install", "telegram"])
        end)

      assert output =~ "installed" or output =~ "instalado" or output =~ "enable"
    end

    test "orienta instalação via Hex para plugin desconhecido" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Plugins.run(["install", "nonexistent_xyz_plugin"])
        end)

      assert output =~ "mix.exs" or output =~ "hex" or output =~ "Hex" or output =~ "dep"
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp write_tmp_config(content) do
    path = Path.join(System.tmp_dir!(), "pincer_test_config_#{System.unique_integer()}.yaml")
    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp channel_enabled?(content, channel_name) do
    # Find the channel block and check that enabled: true appears within it
    pattern = ~r/  #{channel_name}:[\s\S]*?(?=\n  \w|\z)/
    case Regex.run(pattern, content) do
      [block] -> block =~ ~r/enabled:\s*true/
      nil -> false
    end
  end
end
