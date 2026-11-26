defmodule Pincer.CLI do
  @moduledoc """
  CLI Frontend.
  Can run locally (Standalone) or connect to a remote server.
  """
  use Boundary,
    deps: [Pincer.Core, Pincer.Plugin, Pincer.Utils],
    exports: []

  alias Pincer.CLI.History
  alias Pincer.Plugin.Manifest
  alias Pincer.Utils.ANSI
  require Logger

  @session_id "cli_user"
  @default_history_limit 10

  def main(args) do
    IO.puts(ANSI.ok("=== Pincer CLI v0.2 (Distributed) ==="))
    IO.puts("Type /q to exit. Use /history, /history N or /history clear.")

    # If there are arguments, assume they are the desired channels (e.g.: telegram)
    if args != [] do
      IO.puts(ANSI.warn("Active Channel Filter: #{Enum.join(args, ", ")}"))

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
      IO.puts(ANSI.info("🔗 Connected to Immortal Server: #{server_node}"))

      server_node
    else
      IO.puts(ANSI.warn("⚠️ Server not found. Starting Standalone mode..."))

      Mix.Task.run("app.start", [])
      ensure_local_session()
      Node.self()
    end
  end

  defp attach_to_backend(node) do
    try do
      GenServer.call({backend_name(), node}, :attach)
    catch
      :exit, _ ->
        IO.puts(ANSI.error("❌ Failed to connect to CLI channel on server."))

        System.halt(1)
    end
  end

  @doc false
  @spec backend_name() :: module()
  def backend_name do
    case Application.get_env(:pincer, :cli_channel_adapter) do
      nil ->
        Manifest.discover()
        |> Enum.find_value(fn
          %Manifest{id: "cli", adapter: adapter} when not is_nil(adapter) -> adapter
          _ -> nil
        end)
        |> case do
          nil -> raise "CLI channel adapter not found in plugin manifests"
          adapter -> adapter
        end

      adapter ->
        adapter
    end
  end

  @doc false
  @spec prompt_label() :: String.t()
  def prompt_label, do: ANSI.cyan("[User]: ")

  defp ensure_local_session do
    case Registry.lookup(Pincer.Core.Session.Registry, @session_id) do
      [{_pid, _}] -> :ok
      [] -> Pincer.Core.Session.Server.start_link(session_id: @session_id)
    end
  end

  def loop(target_node) do
    input = IO.gets(prompt_label()) |> String.trim()

    case process_command(input) do
      :quit ->
        IO.puts("Goodbye!")
        System.halt(0)

      :clear ->
        IO.puts(ANSI.clear_screen())
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
    target = if is_pid(node), do: node, else: {backend_name(), node}
    GenServer.cast(target, {:user_input, msg})
    :ok
  end

  defp await_response do
    receive do
      {:cli_output, text} ->
        IO.puts(ANSI.ok("[Pincer]: " <> text))

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
      60_000 -> IO.puts(ANSI.error("[Timeout] No response."))
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
      IO.puts(ANSI.warn("[History] No entries yet."))
    else
      IO.puts(ANSI.info("[History] Last #{length(entries)} entries:"))

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
        IO.puts(ANSI.warn("[History] Cleared."))

      {:error, reason} ->
        IO.puts(ANSI.error("[History] Clear failed: #{inspect(reason)}"))
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
