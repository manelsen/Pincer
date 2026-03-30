defmodule Pincer.Core.ReleaseValidation do
  @moduledoc """
  Release-level operational cohesion validation.

  Validates core release criteria:
  - trace + policy coverage
  - project resume reproducibility
  - predictability/recovery explainability
  """

  alias Pincer.Core.Policy

  @type status :: :ok | :error

  @type check :: %{
          id: atom(),
          status: status(),
          message: String.t(),
          details: map()
        }

  @type report :: %{
          run_id: String.t(),
          status: status(),
          release_ready: boolean(),
          checks: [check()],
          summary: String.t()
        }

  @spec run(keyword()) :: report()
  def run(opts \\ []) do
    trace_probe =
      Keyword.get(opts, :trace_probe, fn -> {:ok, %{has_trace: false, policy_routed: false}} end)

    project_probe = Keyword.get(opts, :project_probe, fn -> {:ok, %{reproducible?: false}} end)

    policy_check = validate_policy_kernel()
    trace_check = validate_trace_probe(trace_probe)
    project_check = validate_project_probe(project_probe)

    checks = [policy_check, trace_check, project_check]
    status = if Enum.all?(checks, &(&1.status == :ok)), do: :ok, else: :error

    %{
      run_id: make_run_id(),
      status: status,
      release_ready: status == :ok,
      checks: checks,
      summary: build_summary(status)
    }
  end

  defp validate_policy_kernel do
    required = [allow?: 2, route: 2, budget: 2, guard!: 2, recover: 2, classify: 2]
    loaded? = match?({:module, _}, Code.ensure_loaded(Policy))

    ok? =
      loaded? and
        Enum.all?(required, fn {name, arity} -> function_exported?(Policy, name, arity) end)

    if ok? do
      %{
        id: :policy_coverage,
        status: :ok,
        message: "Policy kernel coverage validated",
        details: %{required: required, loaded?: loaded?}
      }
    else
      %{
        id: :policy_coverage,
        status: :error,
        message: "Policy kernel coverage incomplete",
        details: %{required: required, loaded?: loaded?}
      }
    end
  end

  defp validate_trace_probe(trace_probe) do
    case safe_probe(trace_probe, %{has_trace: false, policy_routed: false}) do
      %{has_trace: true, policy_routed: true} = details ->
        %{
          id: :trace_coverage,
          status: :ok,
          message: "Trace and policy routing verified",
          details: details
        }

      details ->
        %{
          id: :trace_coverage,
          status: :error,
          message: "Trace or policy routing verification failed",
          details: details
        }
    end
  end

  defp validate_project_probe(project_probe) do
    case safe_probe(project_probe, %{reproducible?: false}) do
      %{reproducible?: true} = details ->
        %{
          id: :project_resume,
          status: :ok,
          message: "Project resume is reproducible",
          details: details
        }

      details ->
        %{
          id: :project_resume,
          status: :error,
          message: "Project resume reproducibility failed",
          details: details
        }
    end
  end

  defp safe_probe(fun, fallback) when is_function(fun, 0) do
    try do
      case fun.() do
        {:ok, details} when is_map(details) -> details
        details when is_map(details) -> details
        _ -> fallback
      end
    rescue
      _ -> fallback
    end
  end

  defp build_summary(:ok),
    do:
      "Operational cohesion validated: predictable execution and explicit recovery paths confirmed."

  defp build_summary(:error),
    do:
      "Operational cohesion validation failed: investigate trace/policy coverage and recovery reproducibility."

  defp make_run_id do
    "REL-#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"
  end
end
