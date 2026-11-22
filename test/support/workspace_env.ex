defmodule Pincer.Test.WorkspaceEnv do
  @moduledoc """
  Pins `:pincer, :workspaces_dir` to an absolute temporary directory for the
  duration of a test, restoring the previous value on exit.

  Tests that scaffold workspaces otherwise depend on the process-global cwd,
  which leaks artifacts into the repo's `tmp/` and breaks when another suite
  changes directory. The value is written with `persistent: true` so every
  process reads the same directory.
  """

  @key :workspaces_dir

  @spec put_absolute!(String.t()) :: String.t()
  def put_absolute!(tmp) when is_binary(tmp) do
    previous = Application.fetch_env(:pincer, @key)

    Application.put_env(:pincer, @key, tmp, persistent: true)
    ExUnit.Callbacks.on_exit(fn -> restore(previous) end)

    tmp
  end

  # Deleting (rather than storing a persistent nil) matters: a nil value is
  # found by `get_env/3`, so `AgentPaths.base_dir/0` would stop falling back to
  # "workspaces" and start returning nil for every later test.
  defp restore(:error), do: Application.delete_env(:pincer, @key, persistent: true)

  defp restore({:ok, value}),
    do: Application.put_env(:pincer, @key, value, persistent: true)
end
