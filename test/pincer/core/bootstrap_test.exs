defmodule Pincer.Core.BootstrapTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.Bootstrap

  defmodule StubLLM do
    def chat_completion([%{"role" => "system", "content" => prompt}]) do
      send(self(), {:bootstrap_prompt, prompt})

      {:ok,
       %{
         "content" =>
           Jason.encode!(%{
             "identity" => "# Identity",
             "soul" => "# Soul",
             "user" => "# User"
           })
       }, nil}
    end
  end

  test "build_prompt/1 renders generic user sections without hardcoded personal identifiers" do
    prompt =
      Bootstrap.build_prompt(%{
        name: "Atlas",
        stance: "pragmatic",
        truth: "precision",
        conflict: "direct",
        user_context: "systems engineering"
      })

    assert prompt =~ "USER RESPONSES:"
    assert prompt =~ "`USER.md`: Who the user is and how the agent should serve them."
    assert prompt =~ "- Name: Atlas"
    assert prompt =~ "- Context: systems engineering"
    refute String.contains?(String.downcase(prompt), "manel")
  end

  test "consolidate/2 decodes JSON persona response using injected LLM client" do
    assert {:ok, %{"identity" => "# Identity", "soul" => "# Soul", "user" => "# User"}} =
             Bootstrap.consolidate(%{name: "Atlas"}, llm_client: StubLLM)

    assert_received {:bootstrap_prompt, prompt}
    assert prompt =~ "USER RESPONSES:"
    refute String.contains?(String.downcase(prompt), "manel")
  end
end
