defmodule Mix.Tasks.Pincer.Server do
  @moduledoc """
  Starts the Pincer Server (Persistent Node).
  Usage: mix pincer.server
  """
  use Mix.Task

  def run(args) do
    # Configure the node to be distributed
    start_node()

    if args != [] do
      IO.puts(
        IO.ANSI.yellow() <>
          "Active Channel Filter (Server): #{Enum.join(args, ", ")}" <> IO.ANSI.reset()
      )

      Application.put_env(:pincer, :enabled_channels, args)
    end

    IO.puts(IO.ANSI.green() <> "=== Pincer Server (Immortal Node) ===" <> IO.ANSI.reset())
    IO.puts("Node: #{Node.self()}")
    IO.puts("Cookie: #{Node.get_cookie()}")

    # Start the full application
    Mix.Task.run("app.start", [])

    # Keep the process alive
    Process.sleep(:infinity)
  end

  defp start_node do
    unless Node.alive?() do
      case Node.start(:pincer_server@localhost, :shortnames) do
        {:ok, _} ->
          Node.set_cookie(Node.self(), :pincer_secret)

        {:error, {:already_started, _}} ->
          # Already running, that's fine
          :ok

        {:error, _reason} ->
          # If error (e.g., name in use by another BEAM), try a random name
          suffix = :crypto.strong_rand_bytes(4) |> Base.encode16()
          name = :"pincer_server_#{suffix}@localhost"
          {:ok, _} = Node.start(name, :shortnames)
          Node.set_cookie(Node.self(), :pincer_secret)
      end
    end
  end
end
