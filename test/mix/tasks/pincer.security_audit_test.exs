defmodule Mix.Tasks.Pincer.SecurityAuditTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  @task "pincer.security_audit"

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "pincer_security_audit_task_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    cwd = File.cwd!()
    telegram_token = System.get_env("TELEGRAM_BOT_TOKEN")
    File.cd!(tmp)

    on_exit(fn ->
      File.cd!(cwd)
      restore_env("TELEGRAM_BOT_TOKEN", telegram_token)
      File.rm_rf!(tmp)
      Mix.Task.reenable(@task)
    end)

    :ok
  end

  test "prints warning report and succeeds when only warnings are present" do
    System.put_env("TELEGRAM_BOT_TOKEN", "token-ok")

    write_config!("""
    channels:
      telegram:
        enabled: true
        token_env: "TELEGRAM_BOT_TOKEN"
        dm_policy:
          mode: "open"
    """)

    output =
      capture_io(fn ->
        Mix.Task.run(@task, [])
      end)

    assert output =~ "[WARN]"
    assert output =~ "status: warn"
  end

  test "raises when missing auth exists" do
    System.delete_env("TELEGRAM_BOT_TOKEN")

    write_config!("""
    channels:
      telegram:
        enabled: true
        token_env: "TELEGRAM_BOT_TOKEN"
        dm_policy:
          mode: "allowlist"
          allow_from: ["123"]
    """)

    assert_raise Mix.Error, ~r/blocking security issues/i, fn ->
      capture_io(fn ->
        Mix.Task.run(@task, [])
      end)
    end
  end

  test "strict mode fails when warnings exist" do
    System.put_env("TELEGRAM_BOT_TOKEN", "token-ok")

    write_config!("""
    channels:
      telegram:
        enabled: true
        token_env: "TELEGRAM_BOT_TOKEN"
        dm_policy:
          mode: "open"
    """)

    assert_raise Mix.Error, ~r/security warnings/i, fn ->
      capture_io(fn ->
        Mix.Task.run(@task, ["--strict"])
      end)
    end
  end

  defp write_config!(content) do
    File.write!("config.yaml", String.trim_leading(content))
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
