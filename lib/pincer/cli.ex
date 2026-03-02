defmodule Pincer.CLI do
  @moduledoc """
  CLI Frontend.
  Can run locally (Standalone) or connect to a remote server.
  """
  alias Pincer.CLI.History
  require Logger

  @session_id "cli_user"
  @backend_name Pincer.Channels.CLI
  @default_history_limit 10

  def main(args) do
    IO.puts(IO.ANSI.green() <> "=== Pincer CLI v0.2 (Distributed) ===" <> IO.ANSI.reset())
    IO.puts("Type /q to exit. Use /history, /history N or /history clear.")

    # If there are arguments, assume they are the desired channels (e.g.: telegram)
    if args != [] do
      IO.puts(
        IO.ANSI.yellow() <> "Active Channel Filter: #{Enum.join(args, ", ")}" <> IO.ANSI.reset()
      )

      Application.put_env(:pincer, :enabled_channels, args)
    end

    target_node = connect_to_server()
    attach_to_backend(target_node)
    loop(target_node)
  end

  defp connect_to_server do
    unless Node.alive?() do
      {:ok, _} =
        Node.start(:"pincer_cli_#{System.unique_integer([:positive])}@localhost", :shortnames)

      Node.set_cookie(Node.self(), :pincer_secret)
    end

    server_node = :pincer_server@localhost

    if Node.connect(server_node) do
      IO.puts(
        IO.ANSI.blue() <> "🔗 Connected to Immortal Server: #{server_node}" <> IO.ANSI.reset()
      )

      server_node
    else
      IO.puts(
        IO.ANSI.yellow() <>
          "⚠️ Server not found. Starting Standalone mode..." <> IO.ANSI.reset()
      )

      Mix.Task.run("app.start", [])
      ensure_local_session()
      Node.self()
    end
  end

  defp attach_to_backend(node) do
    try do
      GenServer.call({@backend_name, node}, :attach)
    catch
      :exit, _ ->
        IO.puts(
          IO.ANSI.red() <> "❌ Failed to connect to CLI channel on server." <> IO.ANSI.reset()
        )

        System.halt(1)
    end
  end

  defp ensure_local_session do
    case Registry.lookup(Pincer.Core.Session.Registry, @session_id) do
      [{_pid, _}] -> :ok
      [] -> Pincer.Core.Session.Server.start_link(session_id: @session_id)
    end
  end

  def loop(target_node) do
    input = IO.gets(IO.ANSI.cyan() <> "[User]: " <> IO.ANSI.reset()) |> String.trim()

    case process_command(input) do
      :quit ->
        IO.puts("Goodbye!")
        System.halt(0)

      :clear ->
        IO.puts(IO.ANSI.clear() <> IO.ANSI.home())
        loop(target_node)

      {:history, limit} ->
        print_history(limit)
        loop(target_node)

      :history_clear ->
        clear_history()
        loop(target_node)

      {:send, msg} ->
        persist_input(msg)
        send_message(target_node, msg)
        await_response()
        loop(target_node)
    end
  end

  @spec process_command(String.t()) ::
          :quit | :clear | {:history, pos_integer()} | :history_clear | {:send, String.t()}
  def process_command("/quit"), do: :quit
  def process_command("/q"), do: :quit
  def process_command("/clear"), do: :clear
  def process_command("/history"), do: {:history, @default_history_limit}
  def process_command("/history clear"), do: :history_clear

  def process_command("/history " <> raw_limit) do
    {:history, parse_history_limit(raw_limit)}
  end

  def process_command(msg), do: {:send, msg}

  def send_message(node, msg) do
    # Sends to the Backend on the target node as user INPUT
    target = if is_pid(node), do: node, else: {@backend_name, node}
    GenServer.cast(target, {:user_input, msg})
    :ok
  end

  defp await_response do
    receive do
      {:cli_output, text} ->
        IO.puts("\n" <> IO.ANSI.green() <> "[Pincer]: " <> text <> IO.ANSI.reset() <> "\n")

        # If it's a status message, keep waiting for the final response
        if String.starts_with?(text, "📐") or String.starts_with?(text, "⚙️") do
          await_response()
        else
          # If it's the final response (or error), exits the loop and returns to prompt
          :ok
        end

      _ ->
        await_response()
    after
      60_000 -> IO.puts(IO.ANSI.red() <> "[Timeout] No response." <> IO.ANSI.reset())
    end
  end

  defp parse_history_limit(raw_limit) do
    case Integer.parse(String.trim(raw_limit)) do
      {value, ""} when value > 0 -> value
      _ -> @default_history_limit
    end
  end

  defp print_history(limit) do
    entries = History.recent(limit)

    if entries == [] do
      IO.puts(IO.ANSI.yellow() <> "[History] No entries yet." <> IO.ANSI.reset())
    else
      IO.puts(IO.ANSI.blue() <> "[History] Last #{length(entries)} entries:" <> IO.ANSI.reset())

      entries
      |> Enum.with_index(1)
      |> Enum.each(fn {entry, idx} ->
        IO.puts("#{idx}. #{entry}")
      end)
    end
  end

  defp clear_history do
    case History.clear() do
      :ok ->
        IO.puts(IO.ANSI.yellow() <> "[History] Cleared." <> IO.ANSI.reset())

      {:error, reason} ->
        IO.puts(IO.ANSI.red() <> "[History] Clear failed: #{inspect(reason)}" <> IO.ANSI.reset())
    end
  end

  defp persist_input(msg) do
    case History.append(msg) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[CLI] Failed to persist history entry: #{inspect(reason)}")
    end
  end
end
