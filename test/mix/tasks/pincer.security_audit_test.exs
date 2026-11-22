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
    telegram_token = System.get_env("TELEGRAM_BOT_TOKEN")

    on_exit(fn ->
      restore_env("TELEGRAM_BOT_TOKEN", telegram_token)
      File.rm_rf!(tmp)
      Mix.Task.reenable(@task)
    end)

    %{tmp: tmp}
  end

  test "prints warning report and succeeds when only warnings are present", %{tmp: tmp} do
    System.put_env("TELEGRAM_BOT_TOKEN", "token-ok")

    write_config!(tmp, """
    channels:
      telegram:
        enabled: true
        token_env: "TELEGRAM_BOT_TOKEN"
        dm_policy:
          mode: "open"
    """)

    output =
      capture_io(fn ->
        Mix.Task.run(@task, ["--root", tmp])
      end)

    assert output =~ "[WARN]"
    assert output =~ "Run ID:"
    assert output =~ "status: warn"
  end

  test "raises when missing auth exists", %{tmp: tmp} do
    System.delete_env("TELEGRAM_BOT_TOKEN")

    write_config!(tmp, """
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
        Mix.Task.run(@task, ["--root", tmp])
      end)
    end
  end

  test "strict mode fails when warnings exist", %{tmp: tmp} do
    System.put_env("TELEGRAM_BOT_TOKEN", "token-ok")

    write_config!(tmp, """
    channels:
      telegram:
        enabled: true
        token_env: "TELEGRAM_BOT_TOKEN"
        dm_policy:
          mode: "open"
    """)

    assert_raise Mix.Error, ~r/security warnings/i, fn ->
      capture_io(fn ->
        Mix.Task.run(@task, ["--strict", "--root", tmp])
      end)
    end
  end

  defp write_config!(tmp, content) do
    File.write!(Path.join(tmp, "config.yaml"), String.trim_leading(content))
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
