defmodule Pincer.Storage.Port do
  @moduledoc """
  Defines the behavior (port) for storage operations.
  """
  @callback get_messages(session_id :: String.t()) :: [map()]
  @callback save_message(session_id :: String.t(), role :: String.t(), content :: String.t()) :: {:ok, any()} | {:error, any()}
end
