defmodule Pincer.Orchestration.Blackboard do
  @moduledoc """
  Tiered Event Store: RAM (Hot) + Disk (Cold).
  Automatically retrieves pruned messages from the journal file.
  """
  use GenServer
  require Logger

  @table :pincer_blackboard
  @journal_file "memory/blackboard.journal"
  @ram_threshold_prune 0.80

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{next_id: 1, journal_pid: nil}, name: __MODULE__)
  end

  # --- API ---

  @doc "Compatibility API for posting messages."
  def post(agent_id, content, project_id \\ nil) do
    GenServer.call(__MODULE__, {:post, agent_id, content, project_id})
  end

  @doc "Wait for the journaler to process all pending messages (for tests)."
  def wait_for_journal do
    if p = Process.whereis(:blackboard_journaler) do
      # Envia uma mensagem e espera o retorno, garantindo que a fila anterior foi processada
      ref = make_ref()
      send(p, {:ping, self(), ref})
      receive do
        {:pong, ^ref} -> :ok
      after
        1000 -> :timeout
      end
    end
  end

  @doc "Direct write to ETS. This is what allows 10M+ ops."
  def post_direct(id, agent_id, content, project_id) do
    msg = %{
      id: id,
      agent_id: agent_id,
      project_id: project_id,
      content: content,
      timestamp: DateTime.utc_now()
    }
    
    :ets.insert(@table, {id, msg})
    notify_journaler(msg)
    {:ok, id}
  end

  @doc """
  Fetches new messages. If not in RAM, automatically falls back to Disk Journal.
  """
  def fetch_new(since_id, limit \\ 100) do
    first_key = :ets.first(@table)

    cond do
      # 1. Caso base: Cache vazio ou since_id muito antigo -> Busca no Disco
      first_key == :"$end_of_table" or since_id < first_key ->
        # Busca no disco primeiro
        disk_messages = read_from_journal(since_id, limit)
        
        # Se o disco preencheu o limite, retorna. 
        # Caso contrário, tenta complementar com o que tem na RAM.
        if length(disk_messages) >= limit do
          {disk_messages, List.last(disk_messages).id}
        else
          ram_limit = limit - length(disk_messages)
          ram_since = if Enum.empty?(disk_messages), do: since_id, else: List.last(disk_messages).id
          {ram_messages, last_id} = fetch_from_ram(ram_since, ram_limit)
          {disk_messages ++ ram_messages, last_id}
        end

      # 2. Caso padrão: Tudo está na RAM
      true ->
        fetch_from_ram(since_id, limit)
    end
  end

  # --- Callbacks ---

  @impl true
  def init(state) do
    Application.ensure_all_started(:os_mon)
    :ets.new(@table, [:named_table, :ordered_set, :public, read_concurrency: true, write_concurrency: true])
    
    journaler = spawn_link(fn -> journal_loop() end)
    Process.register(journaler, :blackboard_journaler)

    send(self(), :check_memory_health)
    Logger.info("📚 BLACKBOARD ARMED: Tiered Storage (RAM + Journal Recovery) active.")
    {:ok, %{state | journal_pid: journaler}}
  end

  @impl true
  def handle_call({:post, agent_id, content, project_id}, _from, state) do
    id = state.next_id
    post_direct(id, agent_id, content, project_id)
    {:reply, id, %{state | next_id: id + 1}}
  end

  @impl true
  def handle_info(:check_memory_health, state) do
    Process.send_after(self(), :check_memory_health, 5000)
    usage = try do
      {total, allocated, _} = :memsup.get_memory_data()
      allocated / total
    rescue _ -> 0.0 end

    if usage > @ram_threshold_prune do
      Logger.warning("⚠️ RAM High (#{Float.round(usage * 100, 2)}%). Purging Hot Cache. Data remains safe in Disk Journal.")
      prune_cache()
    end
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # --- Internal Logic: RAM Fetch ---

  defp fetch_from_ram(since_id, limit) do
    spec = [{{:"$1", :"$2"}, [{:>, :"$1", since_id}], [:"$2"]}]
    case :ets.select(@table, spec, limit) do
      {messages, _continuation} -> 
        {messages, List.last(messages).id}
      :"$end_of_table" -> 
        {[], since_id}
      msgs when is_list(msgs) ->
        {msgs, if(Enum.empty?(msgs), do: since_id, else: List.last(msgs).id)}
    end
  end

  # --- Internal Logic: Disk Recovery ---

  defp read_from_journal(since_id, limit) do
    if File.exists?(@journal_file) do
      {:ok, file} = :file.open(@journal_file, [:read, :binary, :raw])
      try do
        iterate_journal(file, since_id, limit, [])
      after
        :file.close(file)
      end
    else
      []
    end
  end

  defp iterate_journal(file, since_id, limit, acc) do
    if length(acc) >= limit do
      Enum.reverse(acc)
    else
      case :file.read(file, 4) do
        {:ok, <<size::32>>} ->
          case :file.read(file, size) do
            {:ok, binary} ->
              msg = :erlang.binary_to_term(binary)
              if msg.id > since_id do
                iterate_journal(file, since_id, limit, [msg | acc])
              else
                iterate_journal(file, since_id, limit, acc)
              end
            _ -> Enum.reverse(acc)
          end
        :eof ->
          Enum.reverse(acc)
        _ -> Enum.reverse(acc)
      end
    end
  end

  # --- Internal Logic: Journaler & Pruning ---

  defp notify_journaler(msg), do: if(p = Process.whereis(:blackboard_journaler), do: send(p, {:journal, msg}))

  defp journal_loop do
    File.mkdir_p!("memory")
    {:ok, file} = File.open(@journal_file, [:append, :raw, :delayed_write])
    receive_loop(file)
  end

  defp receive_loop(file) do
    receive do
      {:journal, msg} ->
        binary = :erlang.term_to_binary(msg)
        :file.write(file, <<byte_size(binary)::32, binary::binary>>)
        receive_loop(file)
      {:ping, from, ref} ->
        # Força o flush do arquivo para o disco antes de responder
        :file.datasync(file)
        send(from, {:pong, ref})
        receive_loop(file)
      :stop -> File.close(file)
    end
  end

  defp prune_cache do
    first = :ets.first(@table)
    delete_half(first, div(:ets.info(@table, :size), 2))
  end

  defp delete_half(:"$end_of_table", _), do: :ok
  defp delete_half(_, 0), do: :ok
  defp delete_half(key, count) do
    next = :ets.next(@table, key)
    :ets.delete(@table, key)
    delete_half(next, count - 1)
  end
end
