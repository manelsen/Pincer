defmodule Pincer.Core.RBAC do
  @moduledoc """
  Simple Role-Based Access Control for Pincer.

  Three roles:
  - `:admin` — full access: config changes, tool approval overrides, audit log access
  - `:operator` — can manage sessions, approve tools, view status
  - `:bot` — message exchange only, no management operations

  Roles are assigned in config.yaml under `agents.<agent_id>.role` or
  per-channel under `channels.<channel>.default_role`.
  """

  @type role :: :admin | :operator | :bot

  @permissions %{
    admin:
      MapSet.new([
        :send_message,
        :manage_sessions,
        :approve_tools,
        :view_audit_log,
        :change_config,
        :manage_agents,
        :view_metrics,
        :override_policy
      ]),
    operator:
      MapSet.new([
        :send_message,
        :manage_sessions,
        :approve_tools,
        :view_metrics,
        :view_audit_log
      ]),
    bot:
      MapSet.new([
        :send_message
      ])
  }

  @doc "Returns true if the given role has the given permission."
  @spec can?(role(), atom()) :: boolean()
  def can?(role, permission) when role in [:admin, :operator, :bot] do
    @permissions
    |> Map.get(role, MapSet.new())
    |> MapSet.member?(permission)
  end

  def can?(_, _), do: false

  @doc "Returns the role for a given agent_id from config, defaulting to :bot."
  @spec role_for(String.t()) :: role()
  def role_for(agent_id) do
    agents = Application.get_env(:pincer, :agents, %{})

    case get_in(agents, [agent_id, :role]) do
      "admin" -> :admin
      "operator" -> :operator
      _ -> :bot
    end
  end

  @doc "Asserts the role has permission, returns {:error, :forbidden} if not."
  @spec authorize(role(), atom()) :: :ok | {:error, :forbidden}
  def authorize(role, permission) do
    if can?(role, permission) do
      :ok
    else
      {:error, :forbidden}
    end
  end

  @doc "Lists all permissions for a role."
  @spec permissions(role()) :: MapSet.t()
  def permissions(role), do: Map.get(@permissions, role, MapSet.new())
end
