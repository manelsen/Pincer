defmodule Pincer.E2E.CIPostureFixtureTest do
  use ExUnit.Case, async: false

  alias Pincer.Core.Doctor
  alias Pincer.Core.SecurityAudit

  @fixture_path Path.expand("../../fixtures/ci_posture/config.yaml", __DIR__)

  setup do
    original_providers = Application.get_env(:pincer, :llm_providers, :__unset__)

    on_exit(fn ->
      case original_providers do
        :__unset__ -> Application.delete_env(:pincer, :llm_providers)
        val -> Application.put_env(:pincer, :llm_providers, val)
      end
    end)

    Application.put_env(:pincer, :llm_providers, %{
      "openrouter" => %{
        adapter: Pincer.LLM.Providers.OpenRouter,
        env_key: "OPENROUTER_API_KEY",
        default_model: "openrouter/free"
      }
    })

    :ok
  end

  test "ci_posture fixture passes Doctor and SecurityAudit strictly with 0 warnings and 0 errors" do
    env_fetcher = fn
      "OPENROUTER_API_KEY" -> "ci-posture-key"
      _ -> nil
    end

    audit_report = SecurityAudit.run(config_file: @fixture_path, env_fetcher: env_fetcher)
    assert audit_report.status == :ok
    assert audit_report.counts.warn == 0
    assert audit_report.counts.error == 0

    doctor_report = Doctor.run(config_file: @fixture_path, env_fetcher: env_fetcher)
    assert doctor_report.counts.error == 0

    for check_id <- [
          :config_yaml,
          :storage_backend,
          :sqlite_path,
          :sqlite_engine,
          {:llm_provider, "openrouter"},
          :policy_kernel,
          :trace_runtime,
          :tool_risk_runtime,
          :memory_health
        ] do
      assert Enum.any?(doctor_report.checks, fn check ->
               check.id == check_id and check.severity == :ok
             end),
             "Expected Doctor check #{inspect(check_id)} to be :ok"
    end
  end

  test "strict posture fails when workspace isolation is disabled or open DM policy is configured" do
    tmp = Path.join(System.tmp_dir!(), "pincer_posture_neg_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    unsafe_cfg = Path.join(tmp, "unsafe.yaml")

    File.write!(unsafe_cfg, """
    storage:
      adapter: "sqlite"
      path: "#{Path.join(tmp, "pincer.db")}"
    tools:
      restrict_to_workspace: false
    channels:
      telegram:
        enabled: true
        token_env: "TELEGRAM_BOT_TOKEN"
        dm_policy:
          mode: "open"
    """)

    audit_report =
      SecurityAudit.run(
        config_file: unsafe_cfg,
        env_fetcher: fn
          "TELEGRAM_BOT_TOKEN" -> "token-ok"
          _ -> nil
        end
      )

    assert audit_report.status == :error
    assert audit_report.counts.error >= 1
    assert audit_report.counts.warn >= 1
  end
end
