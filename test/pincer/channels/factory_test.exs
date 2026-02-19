defmodule Pincer.Channels.Factory.Test do
  use ExUnit.Case
  doctest Pincer.Channels.Factory

  # Mock de canais para teste
  defmodule MockTelegramChannel do
    use GenServer
    @behaviour Pincer.Channel
    def start_link(_opts), do: GenServer.start_link(__MODULE__, %{})
    def send_message(_, _), do: :ok
    def init(_), do: {:ok, %{}}
  end

  defmodule MockSignalChannel do
    use GenServer
    @behaviour Pincer.Channel
    def start_link(_opts), do: GenServer.start_link(__MODULE__, %{})
    def send_message(_, _), do: :ok
    def init(_), do: {:ok, %{}}
  end

  describe "create_channel_specs/1" do
    test "retorna specs apenas para canais habilitados na configuração" do
      config = %{
        "channels" => %{
          "telegram" => %{"enabled" => true, "adapter" => "Pincer.Channels.Factory.Test.MockTelegramChannel"},
          "signal" => %{"enabled" => false, "adapter" => "Pincer.Channels.Factory.Test.MockSignalChannel"}
        }
      }

      specs = Pincer.Channels.Factory.create_channel_specs(config)
      
      # Deve conter apenas o Telegram
      assert length(specs) == 1
      [{module, _opts}] = specs
      assert module == MockTelegramChannel
    end

    test "retorna lista vazia se nenhum canal estiver habilitado" do
      config = %{
        "channels" => %{
          "telegram" => %{"enabled" => false, "adapter" => "MockTelegram"},
          "signal" => %{"enabled" => false, "adapter" => "MockSignal"}
        }
      }

      assert Pincer.Channels.Factory.create_channel_specs(config) == []
    end
  end
end
