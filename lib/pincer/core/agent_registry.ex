defmodule Pincer.Core.AgentRegistry do
  @moduledoc """
  Canonical creator/resolver for root-agent workspaces.

  Agent IDs are internal identifiers. They may be explicit for operator-created
  agents or opaque hexadecimal IDs for auto-provisioned agents.
  """

  alias Pincer.Core.AgentPaths

  @default_hex_bytes 3
  @agent_id_pattern ~r/^[A-Za-z0-9_-]+$/
  @agent_id_description "[A-Za-z0-9_-]+"

  @type create_option ::
          {:agent_id, String.t()}
          | {:bootstrap?, boolean()}
          | {:template_root, String.t()}

  @type create_result :: %{agent_id: String.t(), workspace_path: String.t()}

  @doc """
  Creates or ensures a root-agent workspace exists.

  When `:agent_id` is omitted, generates a new opaque 6-digit hexadecimal ID.
  """
  @spec create_root_agent!([create_option()]) :: create_result()
  def create_root_agent!(opts \\ []) do
    agent_id = normalize_or_generate_agent_id!(Keyword.get(opts, :agent_id))
    workspace_path = AgentPaths.workspace_root(agent_id)

    AgentPaths.ensure_workspace!(workspace_path,
      bootstrap?: Keyword.get(opts, :bootstrap?, true),
      template_root: Keyword.get(opts, :template_root)
    )

    %{agent_id: agent_id, workspace_path: workspace_path}
  end

  @doc """
  Returns whether an agent workspace already exists.
  """
  @spec exists?(String.t()) :: boolean()
  def exists?(agent_id) when is_binary(agent_id) do
    agent_id
    |> AgentPaths.workspace_root()
    |> AgentPaths.pincer_dir()
    |> File.dir?()
  end

  @doc """
  Generates a new opaque hexadecimal agent ID.
  """
  @spec generate_id(keyword()) :: String.t()
  def generate_id(opts \\ []) do
    bytes = Keyword.get(opts, :bytes, @default_hex_bytes)

    bytes
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end

  @doc """
  Validates an explicit operator-provided `agent_id`.
  """
  @spec normalize_agent_id!(String.t()) :: String.t()
  def normalize_agent_id!(agent_id) when is_binary(agent_id) do
    candidate = String.trim(agent_id)

    if String.match?(candidate, @agent_id_pattern) do
      candidate
    else
      raise ArgumentError,
            "Invalid agent_id #{inspect(agent_id)}: agent_id must match #{@agent_id_description}"
    end
  end

  defp normalize_or_generate_agent_id!(nil), do: generate_id()
  defp normalize_or_generate_agent_id!(""), do: generate_id()
  defp normalize_or_generate_agent_id!(agent_id), do: normalize_agent_id!(agent_id)
end
