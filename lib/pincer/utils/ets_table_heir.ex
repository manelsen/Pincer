defmodule Pincer.Utils.ETSTableHeir do
  @moduledoc """
  Heir for the named ETS tables created through `Pincer.Utils.ETSHelper`.

  A named ETS table lives exactly as long as the process that created it. When
  that process is a session, channel or request task, the table dies with it and
  the data it holds is silently lost: cooldowns forget, pairing codes vanish,
  memory budgets stop applying. That failure is invisible in production and
  shows up as an intermittent test only when load happens to line the two events
  up.

  Every table created through `ETSHelper.ensure_named_table/2` therefore names
  this process as its heir. When the creator dies, ownership transfers here
  (`{:ETS-TRANSFER, table, pid, data}`) and the table keeps its contents for the
  lifetime of the node. This process runs no logic of its own, so it is not
  expected to crash; if it is restarted, the tables it held go with it and the
  next creator rebuilds them as it would today.
  """

  use GenServer

  @doc "Starts the heir under the application supervisor."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts), do: {:ok, %{}}

  @doc """
  Takes the table back for the calling process when the heir holds it.

  A restarted owner finds its table alive and owned by the heir. Public tables
  can be written by anyone, but a protected table can only be written by its
  owner, so the restarted owner must reclaim it before writing. Ownership
  transfer after the previous owner's death is asynchronous, hence the retry:
  the table may still be owned by the dead process for a few milliseconds.

  Returns `:ok` when the caller owns the table, `{:error, :not_owner}` when the
  table is owned by an unrelated process that never released it.
  """
  @spec ensure_owned(atom(), non_neg_integer()) :: :ok | {:error, :not_owner}
  def ensure_owned(table, attempts \\ 25) when is_atom(table) do
    case :ets.info(table, :owner) do
      :undefined -> :ok
      pid when pid == self() -> :ok
      _other -> claim_loop(table, attempts)
    end
  end

  defp claim_loop(_table, 0), do: {:error, :not_owner}

  defp claim_loop(table, attempts) do
    case GenServer.call(__MODULE__, {:claim, table, self()}) do
      :ok ->
        :ok

      {:error, :not_owner} ->
        Process.sleep(2)
        claim_loop(table, attempts - 1)
    end
  end

  @impl true
  def handle_call({:claim, table, pid}, _from, state) do
    reply =
      if :ets.info(table, :owner) == self() do
        _ = :ets.give_away(table, pid, :ets_table_heir)
        :ok
      else
        {:error, :not_owner}
      end

    {:reply, reply, state}
  end

  # Ownership arrived from a table whose creator exited. The data is already in
  # the table; keeping the message out of the mailbox is the whole job.
  @impl true
  def handle_info({:"ETS-TRANSFER", _table, _from, _data}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}
end
