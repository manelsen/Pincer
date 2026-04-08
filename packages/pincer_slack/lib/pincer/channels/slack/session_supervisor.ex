defmodule Pincer.Channels.Slack.SessionSupervisor do
  @moduledoc """
  Supervisor for per-channel Slack session workers.
  """
  use DynamicSupervisor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  def start_worker(channel_id) do
    spec = {Pincer.Channels.Slack.Session, channel_id}
    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
