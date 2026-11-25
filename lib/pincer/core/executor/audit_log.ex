defmodule Pincer.Core.Executor.AuditLog do
  @moduledoc """
  Persistent audit log for security-relevant events.
  Every tool approval, policy denial, auth failure, and RBAC decision
  is written here for compliance and post-incident analysis.
  """
  import Pincer.Utils.Validation

  alias Pincer.Ports.AuditLog, as: Store

  defstruct id: nil,
            event_type: nil,
            actor: nil,
            target: nil,
            channel: nil,
            session_id: nil,
            outcome: nil,
            metadata: %{},
            inserted_at: nil

  @required [:event_type, :outcome]
  @optional [:actor, :target, :channel, :session_id, :metadata]

  def changeset(struct \\ %__MODULE__{}, params) do
    struct
    |> cast(params, @required ++ @optional)
    |> validate_required(@required)
  end

  @doc "Record an audit event. Fails silently to avoid disrupting the main flow."
  def record(event_type, outcome, opts \\ []) do
    params = %{
      event_type: to_string(event_type),
      outcome: to_string(outcome),
      actor: opts[:actor],
      target: opts[:target],
      channel: opts[:channel],
      session_id: opts[:session_id],
      metadata: opts[:metadata] || %{}
    }

    changeset = changeset(%__MODULE__{}, params)

    case insert(changeset) do
      :ok ->
        :ok

      {:error, reason} ->
        require Logger
        Logger.warning("AuditLog.record failed: #{inspect(reason)}")
        :ok
    end
  end

  @doc "Query recent audit events, newest first."
  def recent(limit \\ 100) do
    list(:all, limit)
  end

  @doc "Query audit events by actor."
  def by_actor(actor, limit \\ 50) do
    list({:actor, actor}, limit)
  end

  @doc "Query audit events by event type."
  def by_type(event_type, limit \\ 50) do
    list({:type, event_type}, limit)
  end

  defp list(filter, limit) do
    Store.list(filter, limit)
    |> Enum.map(&struct!(__MODULE__, &1))
  end

  defp insert(%{valid?: true} = changeset) do
    changeset |> apply_changes() |> Map.from_struct() |> Store.insert()
  end

  defp insert(changeset), do: {:error, changeset}
end
