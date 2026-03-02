defmodule Mix.Tasks.Pincer.Chat do
  @moduledoc """
  Starts the Pincer CLI.
  Tries to connect to the server (pincer_server). If it fails, starts locally.
  """
  use Mix.Task

  def run(args) do
    # Load .env to ensure configuration (even if connecting remotely)
    load_env()

    # Pincer.CLI decides whether to start the app or connect
    Pincer.CLI.main(args)
  end

  defp load_env do
    if File.exists?(".env") do
      File.stream!(".env")
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == "" or String.starts_with?(&1, "#")))
      |> Enum.each(fn line ->
        [key, value] = String.split(line, "=", parts: 2)
        System.put_env(String.trim(key), String.trim(value))
      end)
    end
  end
end
