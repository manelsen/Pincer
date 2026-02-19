defmodule Pincer.Session.Supervisor do
  @moduledoc """
  DynamicSupervisor responsável por gerenciar os servidores de sessão.
  """
  use DynamicSupervisor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Inicia uma nova sessão.
  """
  def start_session(session_id) do
    child_spec = {Pincer.Session.Server, [session_id: session_id]}
    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end

  @doc """
  Para uma sessão ativa.
  """
  def stop_session(session_id) do
    case Registry.lookup(Pincer.Session.Registry, session_id) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(__MODULE__, pid)
      [] -> {:error, :not_found}
    end
  end
end
