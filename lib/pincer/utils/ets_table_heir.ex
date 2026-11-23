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

  # Ownership arrived from a table whose creator exited. The data is already in
  # the table; keeping the message out of the mailbox is the whole job.
  @impl true
  def handle_info({:"ETS-TRANSFER", _table, _from, _data}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}
end
