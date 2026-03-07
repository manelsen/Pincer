defmodule Pincer.Channels.Discord.API.AdapterTest do
  use ExUnit.Case
  alias Pincer.Channels.Discord.API.Adapter

  # Mock module to simulate Nostrum.Api.Message
  defmodule NostrumMessageMock do
    def create(id, content_or_map) do
      send(self(), {:nostrum_called, id, content_or_map})
      {:ok, %{id: 999}}
    end
  end

  setup do
    # Inject our mock into the Adapter
    Application.put_env(:pincer, :nostrum_message_api, NostrumMessageMock)

    on_exit(fn ->
      Application.delete_env(:pincer, :nostrum_message_api)
    end)

    :ok
  end

  test "create_message handles integer channel_id and delegates to Nostrum" do
    channel_id = 12345
    content = "Hello"

    assert {:ok, %{id: 999}} = Adapter.create_message(channel_id, content, [])

    # Verify the mock received the correct arguments
    assert_receive {:nostrum_called, ^channel_id, ^content}
  end

  test "create_message handles string channel_id and converts to integer" do
    channel_id_str = "67890"
    channel_id_int = 67890
    content = "Hello String"

    assert {:ok, %{id: 999}} = Adapter.create_message(channel_id_str, content, [])

    assert_receive {:nostrum_called, ^channel_id_int, ^content}
  end

  test "create_message merges options into a map for Nostrum" do
    channel_id = 111
    content = "Hello Opts"
    opts = [components: [%{type: 1}]]

    assert {:ok, %{id: 999}} = Adapter.create_message(channel_id, content, opts)

    # Verify we got a MAP with both content and components
    expected_params = %{content: content, components: [%{type: 1}]}
    assert_receive {:nostrum_called, ^channel_id, ^expected_params}
  end
end
