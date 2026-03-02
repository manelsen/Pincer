defmodule Pincer.PubSub do
  @moduledoc """
  A lightweight, local PubSub event bus built on Elixir's Registry.

  PubSub enables decoupled communication between the Core domain logic and
  channel adapters (Telegram, CLI, etc.). Publishers broadcast messages to
  topics, and subscribed processes receive them via their message queue.

  ## Architecture

  ```
  ┌─────────────┐     broadcast     ┌───────────────────┐
  │    Core     │ ────────────────> │   Pincer.PubSub   │
  │  (Domain)   │                   │     Registry      │
  └─────────────┘                   └─────────┬─────────┘
                                              │
                              ┌───────────────┼───────────────┐
                              ▼               ▼               ▼
                         ┌────────┐      ┌────────┐      ┌────────┐
                         │Telegram│      │  CLI   │      │  Web   │
                         │Adapter │      │Adapter │      │Adapter │
                         └────────┘      └────────┘      └────────┘
  ```

  ## Topic Convention

  Topics typically follow the pattern `"session:{session_id}"` to target
  specific user sessions:

      - `"session:telegram:123456789"` - Telegram user's session
      - `"session:cli:admin"` - CLI admin session
      - `"system:broadcast"` - System-wide announcements

  ## Supervision

  PubSub should be started in your application's supervision tree:

      children = [
        {Registry, keys: :duplicate, name: Pincer.PubSub.Registry},
        # or use child_spec:
        Pincer.PubSub,
      ]

  ## Examples

      # Subscribe to a session's events
      Pincer.PubSub.subscribe("session:telegram:123")

      # Process receives messages in handle_info
      def handle_info({:pubsub, topic, message}, state) do
        # Handle the message
        {:noreply, state}
      end

      # Broadcast to all subscribers
      Pincer.PubSub.broadcast("session:telegram:123", {:response, "Hello!"})

  ## Performance

  - Uses partitioned Registry for scalability (`System.schedulers_online/0`)
  - Direct message sending (no serialization overhead)
  - O(n) broadcast where n = number of subscribers on topic
  """
  @registry_name Pincer.PubSub.Registry

  @doc """
  Returns the child specification for starting PubSub under a supervisor.

  Configures a partitioned Registry with duplicate keys, allowing multiple
  processes to subscribe to the same topic.

  ## Options

  Accepts any options but ignores them (for supervisor compatibility).

  ## Examples

      children = [
        Pincer.PubSub,
        # ... other children
      ]

      Supervisor.start_link(children, strategy: :one_for_one)
  """
  @spec child_spec(term()) :: map()
  def child_spec(_) do
    Registry.child_spec(
      keys: :duplicate,
      name: @registry_name,
      partitions: System.schedulers_online()
    )
  end

  @doc """
  Subscribes the calling process to receive messages for a topic.

  When a message is broadcast to the topic, the process will receive it
  in its mailbox. Multiple calls from the same process to the same topic
  are idempotent.

  ## Parameters

    - `topic` - String identifying the subscription channel

  ## Returns

    - `{:ok, _}` or `{:error, _}` from Registry

  ## Examples

      # Subscribe to a session's events
      Pincer.PubSub.subscribe("session:telegram:123")
      # => {:ok, #Reference<...>}

      # Subscribe to system-wide broadcasts
      Pincer.PubSub.subscribe("system:broadcast")

  ## Message Format

  Subscribers receive messages directly via `send/2`. The format depends
  on what the publisher sends:

      # In handle_info:
      def handle_info({:response, text}, state) do
        # Handle response
      end

      def handle_info({:notification, event}, state) do
        # Handle notification
      end
  """
  @spec subscribe(String.t()) :: {:ok, pid()} | {:error, {:already_registered, pid()}}
  def subscribe(topic) do
    Registry.register(@registry_name, topic, [])
  end

  @doc """
  Broadcasts a message to all processes subscribed to a topic.

  Messages are sent directly to each subscriber's mailbox using `send/2`.
  If no processes are subscribed, this is a no-op.

  ## Parameters

    - `topic` - String identifying the broadcast channel
    - `message` - Any Elixir term to send to subscribers

  ## Returns

    - `:ok` always (even if no subscribers exist)

  ## Examples

      # Send a response to session subscribers
      Pincer.PubSub.broadcast("session:telegram:123", {:response, "Hello, world!"})
      # => :ok

      # Broadcast to multiple potential listeners
      Pincer.PubSub.broadcast("system:broadcast", {:shutdown, :maintenance})

      # Custom message format
      Pincer.PubSub.broadcast("session:cli:admin", %{
        type: :progress,
        current: 50,
        total: 100
      })
  """
  @spec broadcast(String.t(), term()) :: :ok
  def broadcast(topic, message) do
    Registry.dispatch(@registry_name, topic, fn entries ->
      for {pid, _} <- entries, do: send(pid, message)
    end)
  end

  @doc """
  Removes the calling process subscription for a topic.

  If the process is not subscribed to the topic, this is a no-op.
  """
  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(topic) do
    Registry.unregister(@registry_name, topic)
  end
end
