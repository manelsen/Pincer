defmodule Pincer.Channels.Discord.API do
  @moduledoc """
  Behavior for Discord API interactions.
  """
  @callback bulk_overwrite_global_commands(commands :: [map()]) :: {:ok, any()} | {:error, any()}
  @callback create_interaction_response(
              interaction_id :: integer(),
              token :: String.t(),
              response :: map()
            ) :: :ok | {:error, any()}
  @callback create_message(channel_id :: integer(), content :: String.t(), opts :: keyword()) ::
              {:ok, any()} | {:error, any()}
  @callback edit_message(channel_id :: integer(), message_id :: integer(), opts :: keyword()) ::
              {:ok, any()} | {:error, any()}
end

defmodule Pincer.Channels.Discord.API.Adapter do
  @moduledoc """
  Real implementation of Discord API using Nostrum.
  """
  @behaviour Pincer.Channels.Discord.API

  @impl true
  def bulk_overwrite_global_commands(commands) do
    nostrum_api(:application_command).bulk_overwrite_global_commands(commands)
  end

  @impl true
  def create_interaction_response(interaction_id, token, response) do
    nostrum_api(:interaction).create_response(interaction_id, token, response)
  end

  @impl true
  def create_message(channel_id, content, opts) do
    # Ensure channel_id is an integer (Discord Snowflake)
    id =
      case channel_id do
        i when is_integer(i) -> i
        s when is_binary(s) -> String.to_integer(s)
        _ -> channel_id
      end

    # Nostrum 0.10+: try map-based options first as it's the modern way
    # If opts is empty, we can just send content.
    if opts == [] or opts == %{} do
      nostrum_api(:message).create(id, content)
    else
      full_opts = opts |> Enum.into(%{}) |> Map.put(:content, content)
      nostrum_api(:message).create(id, full_opts)
    end
  end

  @impl true
  def edit_message(channel_id, message_id, opts) do
    nostrum_api(:message).edit(channel_id, message_id, opts)
  end

  defp nostrum_api(:message),
    do: Application.get_env(:pincer, :nostrum_message_api, Nostrum.Api.Message)

  defp nostrum_api(:interaction),
    do: Application.get_env(:pincer, :nostrum_interaction_api, Nostrum.Api.Interaction)

  defp nostrum_api(:application_command),
    do: Application.get_env(:pincer, :nostrum_app_command_api, Nostrum.Api.ApplicationCommand)
end
