defmodule Pincer.Core.PostureTest do
  use ExUnit.Case, async: false

  alias Pincer.Core.{AccessPolicy, Doctor, Onboard, SecurityAudit}
  alias Pincer.Infra.Config

  test "onboarding rejects the same unsupported backend selected by runtime configuration" do
    original = System.get_env("PINCER_STORAGE")
    System.put_env("PINCER_STORAGE", "postgres")

    on_exit(fn ->
      if original,
        do: System.put_env("PINCER_STORAGE", original),
        else: System.delete_env("PINCER_STORAGE")
    end)

    assert {:error, issues} = Onboard.preflight(Onboard.defaults())
    assert Enum.any?(issues, &(&1.id == :unsupported_storage_backend))
  end

  @tag :tmp_dir
  test "all three commands find the same channel requirements and DM modes", %{tmp_dir: root} do
    path = Path.join(root, "config.yaml")

    File.write!(path, """
    channels:
      webhook:
        enabled: true
      telegram:
        enabled: true
        token_env: TG_TEST_TOKEN
        dm_policy:
          mode: " AllowList "
      discord:
        enabled: true
        token_env: DISCORD_TEST_TOKEN
        dm_policy:
          mode: [invalid]
    """)

    env = fn
      "TG_TEST_TOKEN" -> "fixture"
      _ -> nil
    end

    {:ok, config} = Config.load_file(path)
    doctor = Doctor.run(root: root, env_fetcher: env)
    audit = SecurityAudit.run(root: root, env_fetcher: env)
    onboard = Onboard.assisted_preflight(config, env_fetcher: env)

    assert channel_findings(doctor, :channel_token) == channel_findings(audit, :channel_auth)

    assert channel_findings(onboard, :channel_token) == [
             {"discord", :warn, "DISCORD_TEST_TOKEN"},
             {"telegram", :ok, "TG_TEST_TOKEN"},
             {"webhook", :warn, nil}
           ]

    for report <- [doctor, audit, onboard] do
      assert dm_findings(report) == [
               {"discord", :warn, "invalid"},
               {"telegram", :ok, "allowlist"}
             ]
    end

    assert {:allow, %{mode: :open}} =
             AccessPolicy.authorize_dm(:discord, "123", config["channels"]["discord"])
  end

  defp channel_findings(report, check_id) do
    report.checks
    |> Enum.flat_map(fn
      %{id: {^check_id, channel}, severity: severity, meta: meta} ->
        [{channel, severity, meta[:token_env]}]

      _check ->
        []
    end)
    |> Enum.sort()
  end

  defp dm_findings(report) do
    report.checks
    |> Enum.flat_map(fn
      %{id: {:dm_policy, channel}, severity: severity, meta: %{mode: mode}} ->
        [{channel, severity, mode}]

      _check ->
        []
    end)
    |> Enum.sort()
  end
end
