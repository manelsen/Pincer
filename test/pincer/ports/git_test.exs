defmodule Pincer.Ports.GitTest do
  use ExUnit.Case, async: false

  alias Pincer.Ports.Git

  defmodule Adapter do
    @behaviour Git

    @impl true
    def ensure_branch("project/demo", cwd: "/workspace") do
      {:ok,
       %{
         name: "project/demo",
         status: :created,
         source_branch: "main",
         repo_path: "/workspace",
         bootstrapped: false
       }}
    end

    @impl true
    def files("/workspace", :changed), do: {:error, :git_failed}
  end

  test "delegates branch provisioning and file queries to the configured Git adapter" do
    previous = Application.fetch_env!(:pincer, :git_adapter)
    Application.put_env(:pincer, :git_adapter, Adapter)
    on_exit(fn -> Application.put_env(:pincer, :git_adapter, previous) end)

    assert {:ok, %{repo_path: "/workspace", status: :created}} =
             Git.ensure_branch("project/demo", cwd: "/workspace")

    assert {:error, :git_failed} = Git.files("/workspace", :changed)
  end
end
