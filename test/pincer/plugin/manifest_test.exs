defmodule Pincer.Plugin.ManifestTest do
  use ExUnit.Case, async: true

  alias Pincer.Plugin.Manifest

  @valid_yaml """
  id: telegram
  name: Pincer Telegram
  version: "0.1.0"
  kind: channel
  adapter: "Pincer.Channels.Telegram"
  description: "Telegram channel adapter"
  config_schema:
    token_env:
      type: string
      required: true
      description: "Env var com o token do bot"
    dm_policy:
      type: object
      properties:
        mode:
          type: string
          enum: [open, pairing, disabled]
          default: pairing
  """

  describe "parse/1" do
    test "parseia YAML válido e retorna struct" do
      assert {:ok, manifest} = Manifest.parse(@valid_yaml)
      assert manifest.id == "telegram"
      assert manifest.name == "Pincer Telegram"
      assert manifest.version == "0.1.0"
      assert manifest.kind == :channel
      assert manifest.adapter == Pincer.Channels.Telegram
      assert manifest.description == "Telegram channel adapter"
      assert is_map(manifest.config_schema)
    end

    test "kind é convertido para atom" do
      yaml = String.replace(@valid_yaml, "kind: channel", "kind: storage")
      assert {:ok, manifest} = Manifest.parse(yaml)
      assert manifest.kind == :storage
    end

    test "retorna erro se id estiver ausente" do
      yaml = String.replace(@valid_yaml, "id: telegram\n", "")
      assert {:error, reason} = Manifest.parse(yaml)
      assert reason =~ "id"
    end

    test "retorna erro se name estiver ausente" do
      yaml = String.replace(@valid_yaml, "name: Pincer Telegram\n", "")
      assert {:error, reason} = Manifest.parse(yaml)
      assert reason =~ "name"
    end

    test "retorna erro se kind for inválido" do
      yaml = String.replace(@valid_yaml, "kind: channel", "kind: bananastand")
      assert {:error, reason} = Manifest.parse(yaml)
      assert reason =~ "kind"
    end

    test "adapter é opcional — nil quando ausente" do
      yaml = String.replace(@valid_yaml, ~r/adapter:.*\n/, "")
      assert {:ok, manifest} = Manifest.parse(yaml)
      assert is_nil(manifest.adapter)
    end

    test "config_schema é opcional — mapa vazio quando ausente" do
      yaml = Regex.replace(~r/config_schema:.*\z/s, @valid_yaml, "")
      assert {:ok, manifest} = Manifest.parse(yaml)
      assert manifest.config_schema == %{}
    end

    test "retorna erro em YAML malformado" do
      assert {:error, _reason} = Manifest.parse(":: invalid: yaml: :::")
    end
  end

  describe "from_file/1" do
    test "lê e parseia arquivo YAML existente" do
      path = Path.join([Application.app_dir(:pincer, "priv"), "plugins", "telegram", "pincer_plugin.yaml"])
      assert {:ok, manifest} = Manifest.from_file(path)
      assert manifest.id == "telegram"
      assert manifest.kind == :channel
    end

    test "retorna erro para arquivo inexistente" do
      assert {:error, reason} = Manifest.from_file("/tmp/nao_existe_#{System.unique_integer()}.yaml")
      assert reason =~ "not found"
    end
  end

  describe "discover/0" do
    test "retorna lista de manifests encontrados em priv/plugins/" do
      manifests = Manifest.discover()
      assert is_list(manifests)
      assert Enum.any?(manifests, fn m -> m.id == "telegram" end)
    end
  end
end
