defmodule Pincer.Project.Supervisor do
  @moduledoc """
  Dynamic supervisor for project GenServer processes.
  """
  use DynamicSupervisor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_project(args) do
    DynamicSupervisor.start_child(__MODULE__, {Pincer.Project.Server, args})
  end
end
