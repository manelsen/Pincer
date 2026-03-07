defmodule Pincer.Ports.Cron do
  @moduledoc "Port for cron scheduling operations."

  @callback list_jobs() :: [map()]
  @callback create_job(map()) :: {:ok, map()} | {:error, term()}
  @callback delete_job(String.t()) :: {:ok, map()} | {:error, term()}
  @callback disable_job(String.t()) :: {:ok, map()} | {:error, term()}

  # --- Dispatcher ---

  defp adapter do
    # Default to Pincer.Adapters.Cron.Storage
    Application.get_env(:pincer, :cron_adapter, Pincer.Adapters.Cron.Storage)
  end

  def list_jobs, do: adapter().list_jobs()
  def create_job(params), do: adapter().create_job(params)
  def delete_job(id), do: adapter().delete_job(id)
  def disable_job(id), do: adapter().disable_job(id)
end
