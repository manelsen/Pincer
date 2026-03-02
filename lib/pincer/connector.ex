defmodule Pincer.Connector do
  @moduledoc """
  Behavior for Pincer messaging connectors.
  Defines the interface that every connector must implement.
  """

  @doc """
  Sends a message to the user.
  """
  @callback send_message(destination :: any(), content :: String.t(), opts :: keyword()) ::
              {:ok, any()} | {:error, any()}

  @doc """
  Edits an existing message.
  """
  @callback edit_message(message_ref :: any(), content :: String.t(), opts :: keyword()) ::
              {:ok, any()} | {:error, any()}

  @doc """
  Replies to a message/interaction.
  """
  @callback reply_to(context :: any(), content :: String.t(), opts :: keyword()) ::
              {:ok, any()} | {:error, any()}

  @doc """
  Returns the unique user identifier in the current context.
  """
  @callback user_id(context :: any()) :: String.t()

  @doc """
  Returns the session identifier based on the context.
  """
  @callback session_id(context :: any()) :: String.t()
end
