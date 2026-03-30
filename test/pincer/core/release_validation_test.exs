defmodule Pincer.Core.ReleaseValidationTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.ReleaseValidation

  test "reports release-ready when probes confirm trace and reproducible resume" do
    report =
      ReleaseValidation.run(
        trace_probe: fn -> {:ok, %{has_trace: true, policy_routed: true, provider: "z_ai"}} end,
        project_probe: fn -> {:ok, %{reproducible?: true, resumed_phase: :execution}} end
      )

    assert report.status == :ok
    assert report.release_ready == true
    assert is_binary(report.run_id)

    assert Enum.any?(report.checks, fn check ->
             check.id == :trace_coverage and check.status == :ok
           end)

    assert Enum.any?(report.checks, fn check ->
             check.id == :project_resume and check.status == :ok
           end)

    assert report.summary =~ "Operational cohesion validated"
  end

  test "reports actionable failure when trace or reproducibility probes fail" do
    report =
      ReleaseValidation.run(
        trace_probe: fn -> {:ok, %{has_trace: false, policy_routed: true}} end,
        project_probe: fn -> {:ok, %{reproducible?: false}} end
      )

    assert report.status == :error
    assert report.release_ready == false

    assert Enum.any?(report.checks, fn check ->
             check.id == :trace_coverage and check.status == :error
           end)

    assert Enum.any?(report.checks, fn check ->
             check.id == :project_resume and check.status == :error
           end)

    assert report.summary =~ "validation failed"
  end
end
