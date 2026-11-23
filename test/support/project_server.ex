defmodule Pincer.Test.ProjectServer do
  @moduledoc """
  Teardown helper for tests that own a `Pincer.Core.Project.Server`.

  These tests start the server with `start_link/1`, so the test process owns it
  by link. `on_exit` runs in a different process after the test process has
  exited, by which time the server may be anywhere between fully alive and
  already unregistered. Guarding on `Process.alive?/1` is not enough: the
  process can disappear between that check and the registry lookup inside
  `Pincer.Core.Project.Server.stop/1`, which then exits with `:noproc`.

  Stopping by pid removes the registry lookup from the race, and the `:exit`
  catch covers the remaining window.
  """

  @spec stop(pid() | nil) :: :ok
  def stop(nil), do: :ok

  def stop(pid) when is_pid(pid) do
    try do
      GenServer.stop(pid, :normal, 5_000)
    catch
      :exit, _ -> :ok
    end
  end
end
