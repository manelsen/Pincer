defmodule Pincer.Core.LLM.ModelRouterTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.LLM.ModelRouter

  describe "score/2" do
    test "simple greeting scores low" do
      history = [
        %{"role" => "user", "content" => "hello"}
      ]

      s = ModelRouter.score(history)
      assert s < 0.3
    end

    test "long technical message scores medium-high" do
      code = String.duplicate("defmodule Foo do\n  def bar, do: :ok\nend\n", 20)

      history = [
        %{"role" => "user", "content" => "Refactor this code:\n#{code}"}
      ]

      s = ModelRouter.score(history)
      assert s > 0.3
    end

    test "tool-heavy conversation scores high" do
      history = [
        %{"role" => "user", "content" => "fix all the bugs in the codebase"}
      ] ++
        for i <- 1..6 do
          %{"role" => "tool", "content" => "result #{i} with long output data"}
        end ++
        [
          %{"role" => "assistant", "content" => "fixed 6 issues"},
          %{"role" => "user", "content" => "now refactor the error handling"}
        ]

      s = ModelRouter.score(history)
      assert s > 0.5
    end

    test "empty history returns 0.0" do
      assert ModelRouter.score([]) == 0.0
    end

    test "deep conversation scores higher than shallow" do
      shallow = [%{"role" => "user", "content" => "hi"}]

      deep =
        for i <- 1..20 do
          %{"role" => if(rem(i, 2) == 0, do: "assistant", else: "user"), "content" => "msg #{i}"}
        end

      assert ModelRouter.score(deep) > ModelRouter.score(shallow)
    end
  end

  describe "route/2" do
    test "returns default when router disabled" do
      history = [%{"role" => "user", "content" => "complex request with tools"}]

      assert {:ok, :default} =
               ModelRouter.route(history, enabled: false)
    end

    test "returns default for empty history" do
      assert {:ok, :default} = ModelRouter.route([], enabled: true)
    end

    test "returns appropriate tier for low complexity" do
      tiers = %{
        local: %{provider: "groq", model: "llama-3.3-70b-versatile"},
        fast: %{provider: "groq", model: "llama-3.3-70b-versatile"},
        balanced: %{provider: "z_ai", model: "glm-4.7"},
        powerful: %{provider: "z_ai_coding", model: "glm-4.7"}
      }

      {:ok, tier, _provider, _model} =
               ModelRouter.route([%{"role" => "user", "content" => "hi"}],
                 enabled: true,
                 tiers: tiers
               )

      assert tier in [:local, :fast, :balanced]
    end

    test "returns powerful tier for high complexity" do
      tiers = %{
        local: %{provider: "groq", model: "llama-3.3-70b-versatile"},
        fast: %{provider: "groq", model: "llama-3.3-70b-versatile"},
        balanced: %{provider: "z_ai", model: "glm-4.7"},
        powerful: %{provider: "z_ai_coding", model: "glm-4.7"}
      }

      # Build a maximally complex history: 30 messages, 50% tools, technical content
      history =
        for i <- 1..30 do
          role = if(rem(i, 2) == 0, do: "tool", else: "user")
          content = if(role == "tool", do: String.duplicate("output data ", 100), else: "defmodule Foo do\ndef bar, do: :ok\nend")
          %{"role" => role, "content" => content}
        end

      {:ok, tier, provider, model} =
               ModelRouter.route(history, enabled: true, tiers: tiers)

      assert tier == :powerful
      assert provider == "z_ai_coding"
      assert model == "glm-4.7"
    end

    test "returns default when no tiers configured" do
      assert {:ok, :default} =
               ModelRouter.route([%{"role" => "user", "content" => "hello"}],
                 enabled: true,
                 tiers: %{}
               )
    end
  end
end
