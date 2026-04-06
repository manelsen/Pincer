defmodule Pincer.Adapters.SkillsRegistry.ClawHubTest do
  use ExUnit.Case, async: true

  alias Pincer.Adapters.SkillsRegistry.ClawHub

  defmodule HttpClientStub do
    def get(url, _opts) do
      send(self(), {:http_get, url})

      case Process.get(:clawhub_stub_response) do
        nil -> {:error, :no_stub}
        response -> response
      end
    end
  end

  test "list_skills/1 parses clawhub skills payload" do
    Process.put(
      :clawhub_stub_response,
      {:ok, %{status: 200, body: %{"skills" => [%{"id" => "x"}]}}}
    )

    assert {:ok, [%{"id" => "x"}]} =
             ClawHub.list_skills(http_client: HttpClientStub, base_url: "https://clawhub.local")

    assert_receive {:http_get, "https://clawhub.local/v1/skills"}
  end

  test "fetch_skill/2 parses direct skill payload" do
    Process.put(:clawhub_stub_response, {:ok, %{status: 200, body: %{"id" => "skill-a"}}})

    assert {:ok, %{"id" => "skill-a"}} =
             ClawHub.fetch_skill("skill-a",
               http_client: HttpClientStub,
               base_url: "https://clawhub.local"
             )
  end

  test "fetch_skill/2 returns not_found on 404" do
    Process.put(:clawhub_stub_response, {:ok, %{status: 404, body: %{}}})

    assert {:error, :not_found} =
             ClawHub.fetch_skill("missing", http_client: HttpClientStub, base_url: "https://h")
  end

  test "list_skills/1 rejects invalid payload" do
    Process.put(:clawhub_stub_response, {:ok, %{status: 200, body: %{"unexpected" => true}}})

    assert {:error, :invalid_payload} =
             ClawHub.list_skills(http_client: HttpClientStub, base_url: "https://clawhub.local")
  end
end
