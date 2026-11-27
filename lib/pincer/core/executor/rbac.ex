defmodule Pincer.Core.Executor.RBAC do
  @moduledoc """
  Role-Based Access Control (RBAC) policy for Pincer sessions and tools.

  Three roles:
  - `:admin` — full access: config changes, tool approval overrides, audit log access
  - `:operator` — can manage sessions, approve tools, view status
  - `:bot` — message exchange only, no privileged operations

  Roles can be assigned per agent (`agents.<agent_id>.role`), per channel
  (`channels.<channel>.default_role`), or globally for unconfigured sessions
  (`rbac.unconfigured_role`).
  """

  alias Pincer.Utils.MapHelpers

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

  @doc "Returns the configured role for a given `agent_id`, defaulting to `:bot`."
  @spec role_for(String.t()) :: role()
  def role_for(agent_id) do
    configured_role_for(agent_id) || :bot
  end

  @doc """
  Returns the role explicitly configured for `agent_id`, or `nil` when no role
  is configured. Invalid non-empty role values normalize fail-closed to `:bot`.
  """
  @spec configured_role_for(String.t()) :: role() | nil
  def configured_role_for(agent_id) when is_binary(agent_id) do
    case configured_role(agent_id) do
      nil -> nil
      value -> parse_role(value)
    end
  end

  def configured_role_for(_agent_id), do: nil

  @doc """
  Resolves the effective RBAC role for an execution context (`%Ctx{}` or map/keyword)
  using deterministic precedence:

  1. `agents.<agent_id>.role`
  2. `agents.<session_id>.role` (when distinct from `agent_id`)
  3. `channels.<channel>.default_role`
  4. `rbac.unconfigured_role` (defaults to `:operator` when unset; invalid values fail closed to `:bot`)
  """
  @spec effective_role(map() | keyword()) :: role()
  def effective_role(ctx) when is_list(ctx), do: ctx |> Map.new() |> effective_role()

  def effective_role(ctx) when is_map(ctx) do
    agent_id = non_empty_string(MapHelpers.read_field(ctx, :agent_id))
    session_id = non_empty_string(MapHelpers.read_field(ctx, :session_id))
    channel = MapHelpers.read_field(ctx, :channel)

    configured_role_for(agent_id) ||
      session_fallback_role(agent_id, session_id) ||
      channel_default_role(channel) ||
      unconfigured_role()
  end

  def effective_role(_other), do: unconfigured_role()

  defp session_fallback_role(agent_id, session_id)
       when is_binary(session_id) and session_id != agent_id do
    configured_role_for(session_id)
  end

  defp session_fallback_role(_agent_id, _session_id), do: nil

  defp configured_role(agent_id) do
    agents = Application.get_env(:pincer, :agents, %{})

    if is_map(agents) do
      agents
      |> Map.get(agent_id)
      |> MapHelpers.read_field(:role)
      |> normalize_raw_value()
    else
      nil
    end
  end

  defp channel_default_role(nil), do: nil

  defp channel_default_role(channel) do
    channel_key = channel |> to_string() |> String.trim() |> String.downcase()
    channels = Application.get_env(:pincer, :channels, %{})

    if channel_key != "" and is_map(channels) do
      channels
      |> MapHelpers.read_field(channel_key)
      |> MapHelpers.read_field(:default_role)
      |> normalize_raw_value()
      |> case do
        nil -> nil
        value -> parse_role(value)
      end
    else
      nil
    end
  end

  defp unconfigured_role do
    rbac_cfg = Application.get_env(:pincer, :rbac, %{})
    security_cfg = Application.get_env(:pincer, :security, %{})

    raw =
      normalize_raw_value(MapHelpers.read_field(rbac_cfg, :unconfigured_role)) ||
        normalize_raw_value(MapHelpers.read_field(security_cfg, :unconfigured_role)) ||
        normalize_raw_value(Application.get_env(:pincer, :rbac_unconfigured_role))

    case raw do
      nil -> :operator
      value -> parse_role(value)
    end
  end

  defp parse_role(role) when role in [:admin, :operator, :bot], do: role

  defp parse_role(role) when is_binary(role) do
    case role |> String.trim() |> String.downcase() do
      "admin" -> :admin
      "operator" -> :operator
      _ -> :bot
    end
  end

  defp parse_role(_other), do: :bot

  defp normalize_raw_value(nil), do: nil

  defp normalize_raw_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_raw_value(value), do: value

  defp non_empty_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp non_empty_string(_), do: nil

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
