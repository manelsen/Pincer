defmodule Mix.Tasks.Pincer.Agent do
  @moduledoc """
  Creates and manages explicit root-agent workspaces.

  Usage:

      mix pincer.agent new [agent_id]
      mix pincer.agent pair [agent_id]
  """

  use Mix.Task
  use Boundary, classify_to: Pincer.Mix

  alias Pincer.Core.AgentPaths
  alias Pincer.Core.AgentRegistry
  alias Pincer.Core.Pairing

  @shortdoc "Create and pair explicit root-agent workspaces"
  @usage """
  Usage:
    mix pincer.agent new [agent_id]
    mix pincer.agent pair [agent_id]
  """

  @impl Mix.Task
  def run(["new"]) do
    %{agent_id: agent_id, workspace_path: workspace} =
      AgentRegistry.create_root_agent!()

    Mix.shell().info("Agent ID: #{agent_id}")
    Mix.shell().info("Agent workspace created: #{AgentPaths.pincer_dir(workspace)}")
    Mix.shell().info("Bootstrap file: #{AgentPaths.bootstrap_path(workspace)}")
  end

  def run(["new", agent_id]) do
    normalized_agent_id = normalize_agent_id!(agent_id)
    workspace = AgentPaths.workspace_root(normalized_agent_id)
    pincer_dir = AgentPaths.pincer_dir(workspace)
    existed? = File.dir?(pincer_dir)
    _ = create_named_agent!(normalized_agent_id)

    status = if existed?, do: "already exists", else: "created"

    Mix.shell().info("Agent workspace #{status}: #{pincer_dir}")
    Mix.shell().info("Agent ID: #{normalized_agent_id}")
    Mix.shell().info("Bootstrap file: #{AgentPaths.bootstrap_path(workspace)}")
  end

  def run(["pair"]) do
    issue_pairing_code(nil)
  end

  def run(["pair", agent_id]) do
    normalized_agent_id = normalize_agent_id!(agent_id)
    workspace = AgentPaths.workspace_root(normalized_agent_id)

    if File.dir?(AgentPaths.pincer_dir(workspace)) do
      issue_pairing_code(normalized_agent_id)
    else
      Mix.raise(
        "Agent workspace not found for #{inspect(normalized_agent_id)}. Run `mix pincer.agent new #{normalized_agent_id}` first."
      )
    end
  end

  def run(_args), do: Mix.raise(@usage)

  defp create_named_agent!(agent_id) do
    normalized_agent_id = normalize_agent_id!(agent_id)

    AgentRegistry.create_root_agent!(
      agent_id: normalized_agent_id
    )
  rescue
    error in ArgumentError -> Mix.raise(Exception.message(error))
  end

  defp normalize_agent_id!(agent_id) when is_binary(agent_id) do
    try do
      AgentRegistry.normalize_agent_id!(agent_id)
    rescue
      error in ArgumentError -> Mix.raise(Exception.message(error))
    end
  end

  defp issue_pairing_code(agent_id) do
    {:ok, %{code: code, expires_at_ms: expires_at_ms}} =
      Pairing.issue_invite(:telegram, agent_id: agent_id)

    Mix.shell().info("Channel: telegram")
    Mix.shell().info("Target agent: #{agent_label(agent_id)}")
    Mix.shell().info("Pairing code: #{code}")
    Mix.shell().info("Expires at (ms): #{expires_at_ms}")
    Mix.shell().info("Command: /pair #{code}")
  end

  defp agent_label(nil), do: "<new dedicated Telegram agent>"
  defp agent_label(agent_id), do: agent_id
end
