defmodule Pincer.Core.Reloader do
  @moduledoc """
  Watches the lib/ folder and automatically reloads the code.
  """
  use GenServer
  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Força o início da aplicação de monitoramento de arquivos
    Application.ensure_all_started(:file_system)
    fs_module = Module.concat([FileSystem])
    
    Logger.info("[RELOADER] Initializing Code Watcher...")

    if Code.ensure_loaded?(fs_module) do
      # Trap exits so we don't die if the watcher dies
      Process.flag(:trap_exit, true)

      # Usa o diretório absoluto do projeto
      root_path = File.cwd!()
      lib_path = Path.join(root_path, "lib")
      Logger.info("[RELOADER] Watching path: #{lib_path}")

      case apply(fs_module, :start_link, [[dirs: [lib_path]]]) do
        {:ok, watcher_pid} ->
          apply(fs_module, :subscribe, [watcher_pid])
          Logger.info("[RELOADER] File watcher ACTIVE.")
          {:ok, %{watcher_pid: watcher_pid, timer: nil}}

        error ->
          Logger.error("[RELOADER] FAILED to start watcher: #{inspect(error)}")
          {:stop, :watcher_failed}
      end
    else
      Logger.error("[RELOADER] FileSystem module NOT FOUND. Hot-reload will not work.")
      {:stop, :missing_dependencies}
    end
  end

  @impl true
  def handle_info({:file_event, _watcher_pid, {path, _events}}, state) do
    # Only reloads if it's an Elixir file
    if String.ends_with?(path, ".ex") or String.ends_with?(path, ".exs") do
      # Debounce to avoid multiple consecutive compilations
      if state.timer, do: Process.cancel_timer(state.timer)
      new_timer = Process.send_after(self(), :recompile, 500)
      {:noreply, %{state | timer: new_timer}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:file_event, _watcher_pid, _event}, state) do
    # Ignore control events or other non-path events from FileSystem
    {:noreply, state}
  end

  @impl true
  def handle_info(:recompile, state) do
    Logger.debug("[RELOADER] Change detected. Recompiling...")

    try do
      # 1. Clear compiler cache and rerun compilation
      Mix.Task.clear()
      {status, diagnostics} = Mix.Task.rerun("compile")

      case status do
        :ok ->
          # 2. Extract which files were actually compiled/changed
          changed_beams = get_changed_modules(diagnostics)

          if Enum.empty?(changed_beams) do
            # No actual BEAM changes detected
            :ok
          else
            reload_modules(changed_beams)

            Logger.info("[RELOADER] Success! Hot-reloaded #{length(changed_beams)} modules.")

            # Notify all live sessions to hot-swap their system prompts
            Pincer.Infra.PubSub.broadcast("system:updates", {:system_update_prompt})
          end

        :error ->
          Logger.error("[RELOADER] Compilation failed! Check your syntax errors.")
          
        :noop ->
          :ok
      end
    catch
      kind, error ->
        Logger.error("[RELOADER] Crash during compilation: #{inspect(kind)} - #{inspect(error)}")
    end

    {:noreply, %{state | timer: nil}}
  end

  @impl true
  def handle_info({:EXIT, pid, reason}, %{watcher_pid: pid} = state) do
    Logger.warning("[RELOADER] Watcher process #{inspect(pid)} exited: #{inspect(reason)}. Restarting in 1s...")
    Process.send_after(self(), :init_watcher, 1000)
    {:noreply, %{state | watcher_pid: nil}}
  end

  def handle_info({:EXIT, _pid, :normal}, state) do
    # Silence normal exits to avoid log noise during reloads
    {:noreply, state}
  end

  def handle_info({:EXIT, pid, reason}, state) do
    Logger.debug("[RELOADER] Another linked process #{inspect(pid)} exited: #{inspect(reason)}")
    {:noreply, state}
  end

  def handle_info(:init_watcher, state) do
    # Re-initialize watcher if it died
    case init([]) do
      {:ok, new_state} -> {:noreply, Map.merge(state, new_state)}
      _ -> {:noreply, state}
    end
  end

  # Helpers to emulate IEx recompilation manually
  defp get_changed_modules(_diagnostics) do
    # When Mix compiles, it returns diagnostics or paths. We can also cross-reference `code:modified_modules/0` 
    # but a simpler way is to just find modules that are loaded in memory but have a newer .beam file.
    loaded_modules = 
      :code.all_loaded() 
      |> Enum.map(&elem(&1, 0))
      |> Enum.filter(&(String.starts_with?(to_string(&1), "Elixir.Pincer")))

    Enum.filter(loaded_modules, fn mod ->
      case :code.is_loaded(mod) do
        {:file, path} when is_list(path) ->
          # If the file path is an absolute path to a beam file, check its modification time
          path_str = List.to_string(path)
          String.ends_with?(path_str, ".beam") and module_changed?(mod, path_str)
        _ ->
          false
      end
    end)
  end

  defp module_changed?(mod, path) do
    case :beam_lib.chunks(String.to_charlist(path), [:compile_info]) do
      {:ok, {^mod, [compile_info: _info]}} ->
        # The beam file on disk was compiled. We can check if it's different from the loaded one.
        # But a safer bet is: if the source file is newer than the loaded module's load time, or if we just Mix.compiled, 
        # we can just blindly attempt to reload any module belonging to "pincer" that might have changed.
        true
      _ ->
        false
    end
  end

  # Because detecting EXACT changed modules manually in Elixir is complex without IEx.MixListener,
  # A bulletproof approach for a dev Reloader is to purge and reload all `Pincer.` modules 
  # that were freshly touched by the compiler.
  defp reload_modules(_changed) do
    # 1. Fetch all currently loaded Pincer modules
    pincer_modules = 
      :code.all_loaded()
      |> Enum.map(&elem(&1, 0))
      |> Enum.filter(&(String.starts_with?(to_string(&1), "Elixir.Pincer")))

    # 2. For each module, purge the old version and load the new one from disk
    # We skip the Reloader itself to avoid killing the current process mid-reload.
    # The Reloader will be updated on the next manual restart of the server.
    pincer_modules
    |> Enum.reject(&(&1 == __MODULE__))
    |> Enum.each(fn mod ->
      :code.purge(mod)
      :code.delete(mod)
      
      # Attempt to reload if it still exists (might have been deleted)
      case :code.load_file(mod) do
        {:module, ^mod} -> :ok
        {:error, _} -> :ok # Module might have been removed or renamed
      end
    end)
  end
end
