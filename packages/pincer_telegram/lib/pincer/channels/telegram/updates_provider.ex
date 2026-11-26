defmodule Pincer.Channels.Telegram.UpdatesProvider do
  @moduledoc """
  GenServer that owns the Telegram long-polling loop and `"system:delivery"`
  subscription.

  Delegates polling mechanics to `Pincer.Channels.Telegram.Poller`, update
  dispatch to `Pincer.Channels.Telegram.Update`, command registration to
  `Pincer.Channels.Telegram.Commands`, and inbound media preparation to
  `Pincer.Channels.Telegram.Media`.
  """

  use GenServer
  require Logger

  alias Pincer.Channels.Telegram.{Commands, Media, Poller, Transport}

  @default_offset_path Path.join("sessions", "telegram_update_offset.txt")

  @doc false
  def start_link(opts) do
    opts = if is_list(opts), do: opts, else: []

    offset_path =
      Keyword.get(
        opts,
        :offset_path,
        Application.get_env(:pincer, :telegram_update_offset_path, @default_offset_path)
      )

    GenServer.start_link(
      __MODULE__,
      %{offset: Poller.load_offset(offset_path), failures: 0, offset_path: offset_path},
      name: __MODULE__
    )
  end

  @doc false
  defdelegate load_offset(path), to: Poller

  @doc false
  defdelegate persist_offset(path, offset), to: Poller

  @doc false
  defdelegate next_poll_interval(failures), to: Poller

  @doc false
  @spec prepare_input_content(map(), module()) :: {:ok, String.t() | [map()]} | :empty
  def prepare_input_content(message, api_client \\ Transport.api_client()) do
    Media.prepare_input_content(message, api_client)
  end

  @impl GenServer
  def init(state) do
    if Mix.env() != :test do
      Logger.info("Telegram Poller Started (Manual Mode).")
      PincerPorts.PubSub.subscribe("system:delivery")

      Task.start(fn ->
        Transport.api_client().delete_webhook()
        Commands.register_commands()
      end)

      schedule_poll(Poller.base_poll_interval())
    end

    {:ok, state}
  end

  @impl GenServer
  def handle_info({:deliver_message, session_id, message}, state) do
    Poller.deliver_message(session_id, message)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    {new_offset, failures} = Poller.fetch_updates(state.offset, state.failures, state.offset_path)
    schedule_poll(Poller.next_poll_interval(failures))
    {:noreply, %{state | offset: new_offset, failures: failures}}
  end

  defp schedule_poll(interval_ms) do
    Process.send_after(self(), :poll, interval_ms)
  end
end
