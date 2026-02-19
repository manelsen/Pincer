defmodule Pincer.Connector do
  @moduledoc """
  Behavior para conectores de mensageria do Pincer.
  Define a interface que todo conector deve implementar.
  """

  @doc """
  Envia uma mensagem para o usuário.
  """
  @callback send_message(destination :: any(), content :: String.t(), opts :: keyword()) ::
              {:ok, any()} | {:error, any()}

  @doc """
  Edita uma mensagem existente.
  """
  @callback edit_message(message_ref :: any(), content :: String.t(), opts :: keyword()) ::
              {:ok, any()} | {:error, any()}

  @doc """
  Responde a uma mensagem/interação.
  """
  @callback reply_to(context :: any(), content :: String.t(), opts :: keyword()) ::
              {:ok, any()} | {:error, any()}

  @doc """
  Retorna o identificador único do usuário no contexto atual.
  """
  @callback user_id(context :: any()) :: String.t()

  @doc """
  Retorna o identificador da sessão baseado no contexto.
  """
  @callback session_id(context :: any()) :: String.t()
end
