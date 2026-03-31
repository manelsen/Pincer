defmodule Pincer.Core.PolicyIntegrationTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.Policy

  test "classify supports structured reason metadata for trace-ready decisions" do
    assert Policy.classify(:retryable, %{reason: {:http_error, 503, "upstream"}}) == true
    assert Policy.classify(:fail_fast, %{reason: {:http_error, 401, "unauthorized"}}) == true
    assert Policy.classify(:status_kind, %{text: "Sub-Agent worker running"}) == :subagent
  end
end
