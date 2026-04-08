defmodule Pincer.Channels.Factory.Test do
  use ExUnit.Case, async: true
  doctest Pincer.Channels.Factory

  alias Pincer.Channels.Factory

  # Mock de canais para teste
  defmodule MockTelegramChannel do
    use GenServer
    @behaviour Pincer.Ports.Channel
    def start_link(_opts), do: GenServer.start_link(__MODULE__, %{})
    def send_message(_, _), do: :ok
    def init(_), do: {:ok, %{}}
  end

  defmodule MockSignalChannel do
    use GenServer
    @behaviour Pincer.Ports.Channel
    def start_link(_opts), do: GenServer.start_link(__MODULE__, %{})
    def send_message(_, _), do: :ok
    def init(_), do: {:ok, %{}}
  end

  defmodule MockExtraChild do
    use DynamicSupervisor
    def start_link(_), do: DynamicSupervisor.start_link(__MODULE__, [], name: __MODULE__)
    def init(_), do: DynamicSupervisor.init(strategy: :one_for_one)
  end

  defmodule MockChannelWithExtras do
    @behaviour Pincer.Ports.Channel
    def start_link(_), do: {:ok, self()}
    def send_message(_, _), do: :ok
    def extra_child_specs, do: [MockExtraChild]
  end

  defp clean_whitelist(ctx) do
    old = Application.get_env(:pincer, :enabled_channels)
    Application.delete_env(:pincer, :enabled_channels)

    on_exit(fn ->
      if old, do: Application.put_env(:pincer, :enabled_channels, old)
    end)

    ctx
  end

  describe "create_channel_specs/1" do
    setup :clean_whitelist

    test "retorna specs apenas para canais habilitados na configuração" do
      config = %{
        "channels" => %{
          "telegram" => %{
            "enabled" => true,
            "adapter" => "Pincer.Channels.Factory.Test.MockTelegramChannel"
          },
          "signal" => %{
            "enabled" => false,
            "adapter" => "Pincer.Channels.Factory.Test.MockSignalChannel"
          }
        }
      }

      specs = Factory.create_channel_specs(config)

      assert Enum.any?(specs, fn {m, _} -> m == MockTelegramChannel end)
      assert length(specs) == 1
    end

    test "retorna lista vazia se nenhum canal estiver habilitado" do
      config = %{
        "channels" => %{
          "telegram" => %{"enabled" => false, "adapter" => "MockTelegram"},
          "signal" => %{"enabled" => false, "adapter" => "MockSignal"}
        }
      }

      assert Factory.create_channel_specs(config) == []
    end

    test "inclui extra_child_specs declarados pelo canal" do
      config = %{
        "channels" => %{
          "mock" => %{
            "enabled" => true,
            "adapter" => "Pincer.Channels.Factory.Test.MockChannelWithExtras"
          }
        }
      }

      specs = Factory.create_channel_specs(config)
      modules = Enum.map(specs, fn
        {m, _} -> m
        m when is_atom(m) -> m
      end)

      assert MockChannelWithExtras in modules
      assert MockExtraChild in modules
    end

    test "canais sem extra_child_specs não quebram o factory" do
      config = %{
        "channels" => %{
          "telegram" => %{
            "enabled" => true,
            "adapter" => "Pincer.Channels.Factory.Test.MockTelegramChannel"
          }
        }
      }

      specs = Factory.create_channel_specs(config)

      assert length(specs) == 1
      assert [{MockTelegramChannel, _}] = specs
    end

    test "extra_child_specs aparecem após o spec do canal" do
      config = %{
        "channels" => %{
          "mock" => %{
            "enabled" => true,
            "adapter" => "Pincer.Channels.Factory.Test.MockChannelWithExtras"
          }
        }
      }

      specs = Factory.create_channel_specs(config)

      [{first_module, _} | rest] = specs
      assert first_module == MockChannelWithExtras
      assert [MockExtraChild] == rest
    end
  end

  describe "create_channel_specs/2 — manifest integration" do
    setup :clean_whitelist

    defp manifest(id, adapter) do
      %Pincer.Plugin.Manifest{
        id: id,
        name: id,
        version: "0.1.0",
        kind: :channel,
        adapter: adapter,
        config_schema: %{}
      }
    end

    test "usa adapter do manifest quando config.yaml não declara adapter" do
      config = %{"mock" => %{"enabled" => true}}
      manifests = [manifest("mock", MockTelegramChannel)]

      specs = Factory.create_channel_specs(config, manifests)

      assert [{MockTelegramChannel, _}] = specs
    end

    test "config adapter tem precedência sobre manifest quando ambos existem" do
      config = %{
        "mock" => %{"enabled" => true, "adapter" => "Pincer.Channels.Factory.Test.MockSignalChannel"}
      }
      manifests = [manifest("mock", MockTelegramChannel)]

      specs = Factory.create_channel_specs(config, manifests)

      assert [{MockSignalChannel, _}] = specs
    end

    test "canal habilitado sem adapter em config nem manifest é ignorado" do
      config = %{"ghost" => %{"enabled" => true}}
      specs = Factory.create_channel_specs(config, [])

      assert specs == []
    end

    test "manifests de outros canais não interferem" do
      config = %{
        "mock" => %{"enabled" => true, "adapter" => "Pincer.Channels.Factory.Test.MockTelegramChannel"}
      }
      manifests = [manifest("discord", MockSignalChannel)]

      specs = Factory.create_channel_specs(config, manifests)

      assert [{MockTelegramChannel, _}] = specs
    end
  end
end
