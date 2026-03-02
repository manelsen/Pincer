defmodule Pincer.Core.Project.Registry do
  @moduledoc """
  Global registry for project processes.
  Allows looking up project GenServers by their unique ID.
  """
  def child_spec(_opts) do
    Registry.child_spec(keys: :unique, name: __MODULE__)
  end

  def via_tuple(project_id), do: {:via, Registry, {__MODULE__, project_id}}
end
