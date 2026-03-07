defmodule Pincer.Core.Session.Context do
  @moduledoc """
  Resolved runtime context for a conversation session.
  """

  alias Pincer.Core.AgentPaths

  @enforce_keys [
    :session_id,
    :root_agent_id,
    :root_agent_source,
    :workspace_path,
    :blackboard_scope
  ]
  defstruct [
    :channel,
    :session_id,
    :principal_ref,
    :conversation_ref,
    :root_agent_id,
    :root_agent_source,
    :workspace_path,
    :blackboard_scope
  ]

  @type t :: %__MODULE__{
          channel: atom() | nil,
          session_id: String.t(),
          principal_ref: String.t() | nil,
          conversation_ref: String.t() | nil,
          root_agent_id: String.t(),
          root_agent_source: :session_scope | :static_mapping | :binding,
          workspace_path: String.t(),
          blackboard_scope: String.t()
        }

  @doc """
  Builds the options expected by `Session.Server`.
  """
  @spec to_start_opts(t(), keyword()) :: keyword()
  def to_start_opts(%__MODULE__{} = context, opts \\ []) do
    [
      session_id: context.session_id,
      root_agent_id: context.root_agent_id,
      principal_ref: context.principal_ref,
      conversation_ref: context.conversation_ref,
      workspace_path: context.workspace_path,
      blackboard_scope: context.blackboard_scope,
      allow_legacy_root_seed?: context.root_agent_source == :session_scope
    ] ++ opts
  end

  @doc """
  Builds a new session context map.
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    root_agent_id = Keyword.fetch!(opts, :root_agent_id)

    %__MODULE__{
      channel: Keyword.get(opts, :channel),
      session_id: Keyword.fetch!(opts, :session_id),
      principal_ref: Keyword.get(opts, :principal_ref),
      conversation_ref: Keyword.get(opts, :conversation_ref),
      root_agent_id: root_agent_id,
      root_agent_source: Keyword.get(opts, :root_agent_source, :session_scope),
      workspace_path:
        Keyword.get(opts, :workspace_path, AgentPaths.workspace_root(root_agent_id)),
      blackboard_scope: Keyword.get(opts, :blackboard_scope, root_agent_id)
    }
  end
end
