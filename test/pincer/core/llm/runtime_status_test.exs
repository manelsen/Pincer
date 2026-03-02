defmodule Pincer.Core.LLM.RuntimeStatusTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.LLM.RuntimeStatus

  test "formats retry_wait updates with wait and retries" do
    text =
      RuntimeStatus.format(%{
        kind: :retry_wait,
        reason: "HTTP 429",
        wait_ms: 1_500,
        retries_left: 3
      })

    assert text =~ "HTTP 429"
    assert text =~ "1.5s"
    assert text =~ "3 retries left"
  end

  test "formats failover update for fallback_model" do
    text =
      RuntimeStatus.format(%{
        kind: :failover,
        failover_action: :fallback_model,
        provider: "z_ai",
        model: "glm-4.5",
        reason: "HTTP 429"
      })

    assert text =~ "switched model"
    assert text =~ "z_ai:glm-4.5"
    assert text =~ "HTTP 429"
  end
end
