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
    previous = Application.get_env(:pincer, @key)

    Application.put_env(:pincer, @key, tmp, persistent: true)
    ExUnit.Callbacks.on_exit(fn -> restore(previous) end)

    tmp
  end

  defp restore(nil), do: Application.put_env(:pincer, @key, nil, persistent: true)
  defp restore(value), do: Application.put_env(:pincer, @key, value, persistent: true)
end
