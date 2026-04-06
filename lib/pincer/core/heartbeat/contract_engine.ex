defmodule Pincer.Core.Heartbeat.ContractEngine do
  @moduledoc """
  Promise-based contract engine for proactive agent accountability.

  Agents make promises during turns (e.g. "Monitor repo X for new commits").
  On each heartbeat pulse, `evaluate/1` checks which promises are still pending,
  which have expired past their deadline, and which have been fulfilled.

  State is stored in a named ETS table for concurrent access.
  """

  @table :contract_engine

  @type promise :: %{
          id: String.t(),
          description: String.t(),
          status: :pending | :fulfilled | :expired,
          made_at: DateTime.t(),
          deadline: DateTime.t() | nil
        }

  @doc "Ensure the ETS table exists. Call once at startup or let it lazily create."
  @spec init() :: :ok
  def init do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :set, :public])
    end

    :ok
  end

  @doc "Record a promise from an agent."
  @spec make_promise(String.t(), String.t(), keyword()) :: :ok
  def make_promise(agent_id, description, opts \\ []) do
    init()

    promise = %{
      id: "promise_#{:rand.uniform(1_000_000)}",
      description: description,
      status: :pending,
      made_at: DateTime.utc_now(),
      deadline: Keyword.get(opts, :deadline)
    }

    existing = :ets.lookup(@table, agent_id)

    promises =
      case existing do
        [{^agent_id, list}] -> list ++ [promise]
        _ -> [promise]
      end

    :ets.insert(@table, {agent_id, promises})
    :ok
  end

  @doc "Evaluate all promises for an agent. Updates statuses in place."
  @spec evaluate(String.t()) :: [{:expired | :pending | :fulfilled, promise()}]
  def evaluate(agent_id) do
    init()

    case :ets.lookup(@table, agent_id) do
      [{^agent_id, promises}] ->
        now = DateTime.utc_now()

        updated =
          Enum.map(promises, fn p ->
            cond do
              p.status == :fulfilled ->
                p

              p.status == :pending and p.deadline != nil and DateTime.compare(p.deadline, now) == :lt ->
                %{p | status: :expired}

              true ->
                p
            end
          end)

        :ets.insert(@table, {agent_id, updated})

        updated
        |> Enum.map(fn p -> {p.status, p} end)

      _ ->
        []
    end
  end

  @doc "Get all pending promises for an agent."
  @spec pending(String.t()) :: [promise()]
  def pending(agent_id) do
    init()

    case :ets.lookup(@table, agent_id) do
      [{^agent_id, promises}] ->
        Enum.filter(promises, fn p -> p.status == :pending end)

      _ ->
        []
    end
  end

  @doc "Mark a specific promise as fulfilled."
  @spec fulfill(String.t(), String.t()) :: :ok
  def fulfill(agent_id, promise_id) do
    init()

    case :ets.lookup(@table, agent_id) do
      [{^agent_id, promises}] ->
        updated =
          Enum.map(promises, fn p ->
            if p.id == promise_id do
              %{p | status: :fulfilled}
            else
              p
            end
          end)

        :ets.insert(@table, {agent_id, updated})
        :ok

      _ ->
        :ok
    end
  end
end
