defmodule Pincer.Channel do
  @moduledoc """
  Interface (Behaviour) para canais de comunicação do Pincer.
  
  Todo canal deve implementar este contrato:
  - `start_link/1`: Inicia o processo (GenServer) que escuta/recebe mensagens.
  - `send_message/2`: Envia uma mensagem para um destinatário neste canal.
  """

  @doc "Inicia o canal com a configuração do config.yaml"
  @callback start_link(config :: map()) :: GenServer.on_start()

  @doc "Envia uma mensagem (String) para um destinatário identificado por ID"
  @callback send_message(recipient_id :: String.t(), content :: String.t()) :: :ok | {:error, any()}

  @optional_callbacks send_message: 2

  defmacro __using__(_opts) do
    quote do
      @behaviour Pincer.Channel
      use GenServer
      require Logger
      
      def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
      def init(state), do: {:ok, state}
    end
  end
end
