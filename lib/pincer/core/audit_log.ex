defmodule Pincer.Core.AuditLog do
  @moduledoc """
  Persistent audit log for security-relevant events.
  Every tool approval, policy denial, auth failure, and RBAC decision
  is written here for compliance and post-incident analysis.
  """
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Pincer.Infra.Repo

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "audit_log" do
    field :event_type, :string
    field :actor, :string
    field :target, :string
    field :channel, :string
    field :session_id, :string
    field :outcome, :string
    field :metadata, :map, default: %{}
    field :inserted_at, :utc_datetime_usec, autogenerate: {DateTime, :utc_now, []}
  end

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

    %__MODULE__{}
    |> changeset(params)
    |> Repo.insert()
    |> case do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        require Logger
        Logger.warning("AuditLog.record failed: #{inspect(reason)}")
        :ok
    end
  end

  @doc "Query recent audit events, newest first."
  def recent(limit \\ 100) do
    from(a in __MODULE__,
      order_by: [desc: a.inserted_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc "Query audit events by actor."
  def by_actor(actor, limit \\ 50) do
    from(a in __MODULE__,
      where: a.actor == ^actor,
      order_by: [desc: a.inserted_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc "Query audit events by event type."
  def by_type(event_type, limit \\ 50) do
    from(a in __MODULE__,
      where: a.event_type == ^event_type,
      order_by: [desc: a.inserted_at],
      limit: ^limit
    )
    |> Repo.all()
  end
end
